use std::{
    collections::BTreeMap,
    time::{SystemTime, UNIX_EPOCH},
};

use once_cell::sync::Lazy;
use regex::Regex;
use scraper::{ElementRef, Html, Selector};
use serde_json::{json, Value};

use crate::{
    error::{CoreError, CoreResult},
    model::{CloudItem, ManagedMetadata, ShareRecord},
};

pub fn api_json(body: &str) -> CoreResult<Value> {
    let value: Value =
        serde_json::from_str(body).map_err(|_| CoreError::parse("蓝奏云返回了无法识别的数据"))?;
    let status = value.get("zt").and_then(value_as_i64).unwrap_or_default();
    match status {
        1 | 2 | 4 => Ok(value),
        9 => Err(CoreError::session_expired()),
        _ => {
            let message = value
                .get("inf")
                .or_else(|| value.get("info"))
                .and_then(Value::as_str)
                .map(sanitize_message)
                .filter(|text| !text.is_empty())
                .unwrap_or_else(|| "蓝奏云操作失败".to_owned());
            Err(CoreError::remote(message, status == 4))
        }
    }
}

pub fn value_as_i64(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
}

pub fn list_items(value: &Value, is_folder: bool) -> CoreResult<Vec<CloudItem>> {
    let array = value
        .get("text")
        .and_then(Value::as_array)
        .ok_or_else(|| CoreError::parse("文件列表字段缺失"))?;
    array
        .iter()
        .map(|item| {
            let id_key = if is_folder { "fol_id" } else { "id" };
            let name_key = if is_folder { "name" } else { "name_all" };
            let id = string_field(item, id_key)?;
            let name = string_field(item, name_key)?.replace("&amp;", "&");
            let mut cloud = if is_folder {
                CloudItem::folder(id, name)
            } else {
                CloudItem::file(id, name)
            };
            cloud.size = optional_string(item, "size");
            cloud.modified_at = optional_string(item, "time");
            cloud.description = optional_string(item, "folder_des")
                .map(|text| text.trim_matches(&['[', ']'][..]).to_owned());
            cloud.has_password = item
                .get("onof")
                .and_then(value_as_i64)
                .map(|status| status == 1);
            cloud.downloads = item
                .get("downs")
                .and_then(value_as_i64)
                .and_then(|count| u64::try_from(count).ok());
            if !is_folder {
                cloud.has_custom_icon = item
                    .get("is_ico")
                    .or_else(|| item.get("p_ico"))
                    .and_then(value_as_i64)
                    .map(|status| status == 1);
                if cloud.has_custom_icon == Some(true) {
                    cloud.icon_url =
                        optional_string(item, "ico").and_then(|value| trusted_icon_url(&value));
                }
            }
            Ok(cloud)
        })
        .collect()
}

pub fn move_targets(value: &Value) -> CoreResult<Vec<CloudItem>> {
    let mut result = vec![CloudItem {
        path: Some("/".to_owned()),
        ..CloudItem::folder("-1", "LanzouYOU")
    }];
    let Some(array) = value.get("info").and_then(Value::as_array) else {
        return Ok(result);
    };
    for entry in array {
        let id = string_field(entry, "folder_id")?;
        let name = string_field(entry, "folder_name")?;
        result.push(CloudItem::folder(id, name));
    }
    Ok(result)
}

pub fn share_record(value: &Value, is_folder: bool) -> CoreResult<ShareRecord> {
    let info = value
        .get("info")
        .ok_or_else(|| CoreError::parse("分享信息字段缺失"))?;
    let enabled = optional_string(info, "onof").as_deref() == Some("1");
    let password = if enabled {
        optional_string(info, "pwd").unwrap_or_default()
    } else {
        String::new()
    };
    if is_folder {
        let name = optional_string(info, "name").unwrap_or_default();
        let url = string_field(info, "new_url")?;
        Ok(ShareRecord {
            name,
            url: absolute_share_url(&url),
            password,
            description: optional_string(info, "des").unwrap_or_default(),
        })
    } else {
        let share_id = string_field(info, "f_id")?;
        if share_id == "i" {
            return Err(CoreError::new("not_found", "文件不存在", false));
        }
        let base = optional_string(info, "is_newd")
            .filter(|text| !text.is_empty())
            .unwrap_or_else(|| "https://wws.lanzoui.com".to_owned());
        Ok(ShareRecord {
            name: String::new(),
            url: format!("{}/{}", base.trim_end_matches('/'), share_id),
            password,
            description: String::new(),
        })
    }
}

pub(crate) fn managed_file_metadata(value: &Value) -> CoreResult<ManagedMetadata> {
    Ok(ManagedMetadata {
        name: present_string(value, "text", "文件信息缺少 text")?,
        description: present_string(value, "info", "文件信息缺少 info")?,
    })
}

pub(crate) fn managed_folder_metadata(value: &Value) -> CoreResult<ManagedMetadata> {
    let info = value
        .get("info")
        .and_then(Value::as_object)
        .ok_or_else(|| CoreError::parse("目录信息缺少 info"))?;
    Ok(ManagedMetadata {
        name: present_string_in_object(info, "name", "目录信息缺少 name")?,
        description: present_string_in_object(info, "des", "目录信息缺少 des")?,
    })
}

pub(crate) fn upload_file_id(value: &Value) -> CoreResult<Option<String>> {
    let Some(text) = value.get("text") else {
        return Err(CoreError::parse("上传响应缺少 text"));
    };
    let candidate = match text {
        Value::Array(items) => items.first().and_then(|item| item.get("id")),
        Value::Object(item) => item.get("id"),
        value => Some(value),
    };
    match candidate {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value_to_id(value)
            .map(Some)
            .ok_or_else(|| CoreError::parse("上传响应 id 无效")),
    }
}

pub fn bootstrap_values(html: &str) -> CoreResult<(String, String)> {
    ensure_session_html(html)?;
    let uid = capture(html, r#"uid=([^'\"&;\s]+)"#).ok_or_else(CoreError::session_expired)?;
    let fields = js_data_fields(html)?;
    let vei = fields
        .get("vei")
        .cloned()
        .ok_or_else(|| CoreError::parse("登录页面缺少 vei"))?;
    Ok((uid, vei))
}

pub fn ensure_session_html(html: &str) -> CoreResult<()> {
    let document = Html::parse_document(html);
    let title_selector = static_selector("title");
    let title = document
        .select(&title_selector)
        .map(element_text)
        .collect::<Vec<_>>()
        .join(" ");
    let compact_title = title
        .chars()
        .filter(|character| !character.is_whitespace())
        .collect::<String>();
    let password_selector =
        static_selector(r#"input[type="password"], input[name="password"], input[name="passwd"]"#);
    let visible = visible_text(&document);
    let has_login_form = document.select(&password_selector).next().is_some()
        && (visible.contains("登录") || visible.contains("登陆"));
    let has_login_title = ["网盘用户登录", "用户登录", "登录蓝奏云"]
        .iter()
        .any(|marker| compact_title.contains(marker));

    if has_login_title || has_login_form {
        Err(CoreError::session_expired())
    } else {
        Ok(())
    }
}

pub const ACCOUNT_PORTAL_URL: &str =
    "https://pc.woozooo.com/mydisk.php?item=profile&action=mypower";
pub const MEMBERSHIP_PORTAL_URL: &str =
    "https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan";

pub fn account_surface(mypower_html: &str, huiyuan_html: &str) -> CoreResult<Value> {
    ensure_session_html(mypower_html)?;
    ensure_session_html(huiyuan_html)?;

    let mypower = Html::parse_document(mypower_html);
    let huiyuan = Html::parse_document(huiyuan_html);
    let mypower_text = visible_text(&mypower);
    let huiyuan_text = visible_text(&huiyuan);

    Ok(json!({
        "membershipProfile": membership_profile(&mypower),
        "entries": account_entries(&mypower_text),
        "facts": account_facts(&mypower),
        "plans": membership_plans(&huiyuan),
        "personalization": personalization_features(&huiyuan_text),
    }))
}

fn membership_profile(document: &Html) -> Value {
    let status = structured_value(document, &["会员状态", "我的会员", "账号级别", "会员等级"]);
    let level = structured_value(document, &["会员等级", "账号级别"]);
    let expires_at = structured_value(
        document,
        &["会员到期", "到期时间", "有效期至", "会员有效期"],
    )
    .and_then(|value| normalized_membership_date(&value));
    let expired = status
        .as_deref()
        .is_some_and(is_explicit_expired_membership)
        || expires_at
            .as_deref()
            .is_some_and(membership_date_has_passed);
    let state = match status.as_deref() {
        _ if expired => "free",
        Some(value) if is_explicit_free_membership(value) => "free",
        Some(value) if is_explicit_vip_membership(value) => "vip",
        _ => "unknown",
    };
    let display_name = if expired {
        "会员已过期".to_owned()
    } else {
        status.unwrap_or_else(|| match state {
            "vip" => "会员用户".to_owned(),
            "free" => "免费用户".to_owned(),
            _ => "会员状态未知".to_owned(),
        })
    };
    let reason = match (state, expired) {
        (_, true) => "蓝奏云个人页返回的会员状态或到期日期表明会员已过期",
        ("vip", false) => "蓝奏云个人页返回了明确的会员状态标签",
        ("free", false) => "蓝奏云个人页返回了明确的免费或未开通会员标签",
        _ => "蓝奏云个人页未返回可确认的会员状态标签",
    };

    let mut profile = serde_json::Map::new();
    profile.insert("state".to_owned(), Value::String(state.to_owned()));
    profile.insert("displayName".to_owned(), Value::String(display_name));
    if let Some(level) = level {
        profile.insert("level".to_owned(), Value::String(level));
    }
    if let Some(expires_at) = expires_at {
        profile.insert("expiresAt".to_owned(), Value::String(expires_at));
    }
    profile.insert("reason".to_owned(), Value::String(reason.to_owned()));
    Value::Object(profile)
}

fn is_explicit_free_membership(value: &str) -> bool {
    [
        "非会员",
        "免费用户",
        "普通用户",
        "未开通",
        "免费版",
        "无会员",
    ]
    .iter()
    .any(|marker| value.contains(marker))
}

fn is_explicit_expired_membership(value: &str) -> bool {
    [
        "会员已过期",
        "会员过期",
        "已到期会员",
        "过期会员",
        "VIP已过期",
    ]
    .iter()
    .any(|marker| {
        value
            .to_ascii_uppercase()
            .contains(&marker.to_ascii_uppercase())
    })
}

fn is_explicit_vip_membership(value: &str) -> bool {
    !is_explicit_expired_membership(value)
        && !is_explicit_free_membership(value)
        && (value.to_ascii_uppercase().contains("VIP") || value.contains("会员"))
}

static MEMBERSHIP_DATE_PATTERN: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r#"(?x)
        (?P<year>\d{4})
        (?:-|/|\.|年)
        (?P<month>\d{1,2})
        (?:-|/|\.|月)
        (?P<day>\d{1,2})
        日?
        "#,
    )
    .expect("membership date regex must be valid")
});

fn normalized_membership_date(value: &str) -> Option<String> {
    let captures = MEMBERSHIP_DATE_PATTERN.captures(value)?;
    let year = captures.name("year")?.as_str().parse::<u32>().ok()?;
    let month = captures.name("month")?.as_str().parse::<u32>().ok()?;
    let day = captures.name("day")?.as_str().parse::<u32>().ok()?;
    let max_day = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) => 29,
        2 => 28,
        _ => return None,
    };
    if day == 0 || day > max_day {
        return None;
    }
    Some(format!("{year:04}-{month:02}-{day:02}"))
}

fn membership_date_has_passed(value: &str) -> bool {
    let Some(expiry_days) = unix_days_from_iso_date(value) else {
        return false;
    };
    let Some(today_days) = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|duration| (duration.as_secs() / 86_400) as i64)
    else {
        return false;
    };
    expiry_days < today_days
}

fn unix_days_from_iso_date(value: &str) -> Option<i64> {
    let mut parts = value.split('-');
    let year = parts.next()?.parse::<i64>().ok()?;
    let month = parts.next()?.parse::<i64>().ok()?;
    let day = parts.next()?.parse::<i64>().ok()?;
    if parts.next().is_some() || !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let adjusted_year = year - i64::from(month <= 2);
    let era = if adjusted_year >= 0 {
        adjusted_year
    } else {
        adjusted_year - 399
    } / 400;
    let year_of_era = adjusted_year - era * 400;
    let adjusted_month = month + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * adjusted_month + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    Some(era * 146_097 + day_of_era - 719_468)
}

fn account_entries(visible: &str) -> Vec<Value> {
    [
        (
            "permissions",
            "我的权限",
            "查看账号权限与用量",
            ACCOUNT_PORTAL_URL,
            false,
            false,
        ),
        (
            "balance",
            "财务充值",
            "查看余额并在官方页面确认充值",
            "https://pc.woozooo.com/mydisk.php?item=profile&action=goods",
            true,
            false,
        ),
        (
            "fileUpgrade",
            "文件升级",
            "查看单文件升级服务",
            "https://pc.woozooo.com/mydisk.php?item=profile&action=buygoods",
            true,
            false,
        ),
        (
            "downloadCashout",
            "下载提现",
            "进入官方下载提现页面",
            "https://pc.woozooo.com/mydisk.php?item=profile&action=exchange",
            true,
            false,
        ),
        (
            "cashoutRecords",
            "提现记录",
            "查看官方下载提现记录",
            "https://pc.woozooo.com/mydisk.php?item=profile&action=orders",
            false,
            false,
        ),
        (
            "invite",
            "邀请注册",
            "查看官方邀请入口",
            "https://pc.woozooo.com/mydisk.php?item=buddy&action=invite",
            false,
            false,
        ),
        (
            "password",
            "密码修改",
            "在官方页面验证并修改账号密码",
            "https://pc.woozooo.com/mydisk.php?item=profile&action=password",
            true,
            false,
        ),
        (
            "phone",
            "手机号",
            "在官方页面验证并更换手机号",
            ACCOUNT_PORTAL_URL,
            true,
            false,
        ),
        (
            "closeAccount",
            "注销账户",
            "注销后账号与数据可能无法恢复",
            ACCOUNT_PORTAL_URL,
            true,
            true,
        ),
    ]
    .into_iter()
    .map(
        |(id, title, description, portal_url, confirmation, dangerous)| {
            json!({
                "id": id,
                "title": title,
                "description": description,
                "portalUrl": portal_url,
                "available": visible.contains(title),
                "requiresOfficialConfirmation": confirmation,
                "dangerous": dangerous,
            })
        },
    )
    .collect()
}

fn account_facts(document: &Html) -> Vec<Value> {
    [
        ("singleFileLimit", "单个文件大小"),
        ("storageStatistics", "云存储统计"),
        ("downloadWithoutLogin", "下载免登录"),
        ("downloadSpeed", "下载速度"),
        ("downloadCount", "下载次数"),
        ("downloadTraffic", "下载流量"),
        ("storageCapacity", "存储空间"),
        ("allowedUploadTypes", "允许上传类型"),
    ]
    .into_iter()
    .map(|(id, label)| {
        let value = structured_value(document, &[label]);
        let mut fact = serde_json::Map::new();
        fact.insert("id".to_owned(), Value::String(id.to_owned()));
        fact.insert("label".to_owned(), Value::String(label.to_owned()));
        fact.insert("known".to_owned(), Value::Bool(value.is_some()));
        if let Some(value) = value {
            fact.insert("value".to_owned(), Value::String(value));
        }
        Value::Object(fact)
    })
    .collect()
}

fn membership_plans(document: &Html) -> Vec<Value> {
    [
        ("month1", "1个月", &["1个月", "1月"][..]),
        ("month2", "2个月", &["2个月", "2月"][..]),
        ("month6", "6个月", &["6个月", "6月"][..]),
        ("year1", "1年", &["1年", "12个月"][..]),
        ("monthly", "包月", &["包月"][..]),
        ("yearly", "包年", &["包年"][..]),
        ("downloadPack", "下载包", &["下载包"][..]),
    ]
    .into_iter()
    .map(|(id, label, aliases)| {
        let candidate = plan_candidate(document, aliases);
        let available = candidate.is_some();
        let price_label = candidate.as_deref().and_then(extract_price);
        let discount = candidate.as_deref().and_then(extract_discount);
        let detail = discount
            .map(|discount| format!("官方页面标注 {discount}"))
            .unwrap_or_else(|| "价格与权益以蓝奏云官方页面实时信息为准".to_owned());
        let mut plan = serde_json::Map::new();
        plan.insert("id".to_owned(), Value::String(id.to_owned()));
        plan.insert("label".to_owned(), Value::String(label.to_owned()));
        plan.insert("detail".to_owned(), Value::String(detail));
        if let Some(price_label) = price_label {
            plan.insert("priceLabel".to_owned(), Value::String(price_label));
        }
        plan.insert("available".to_owned(), Value::Bool(available));
        Value::Object(plan)
    })
    .collect()
}

fn personalization_features(visible: &str) -> Vec<Value> {
    [
        ("adFreeDownloads", "免广告下载", "会员下载页可免除广告等待"),
        (
            "uploadTimeVisibility",
            "上传时间隐藏/显示",
            "控制分享页上传时间显示",
        ),
        ("subfolders", "子文件夹", "使用分享目录中的子文件夹"),
        ("search", "搜索", "使用会员搜索能力"),
        (
            "defaultFilePassword",
            "新文件密码默认开关",
            "控制新上传文件的默认密码状态",
        ),
        ("avatarUpload", "头像上传", "设置账号头像"),
        ("downloadPageTemplate", "下载页模板", "选择官方下载页模板"),
        ("publisherNickname", "发布者昵称", "设置分享页发布者昵称"),
        ("dailyDownloadReport", "日下载报表", "查看每日下载统计报表"),
        ("fileRetention", "文件保存时间", "查看会员文件保存期限权益"),
        ("directLinkDomain", "直链域名绑定", "配置直链域名及备案信息"),
    ]
    .into_iter()
    .map(|(id, title, description)| {
        let available = visible.contains(title);
        json!({
            "id": id,
            "title": title,
            "description": description,
            "available": available,
            "writable": false,
            "reason": if available {
                "蓝奏云会员页当前展示该功能；设置仍需在官方页面确认"
            } else {
                "蓝奏云会员页未明确展示该功能，可能受页面改版或账号状态影响"
            },
        })
    })
    .collect()
}

fn visible_text(document: &Html) -> String {
    let all = static_selector("*");
    document
        .select(&all)
        .filter(|element| {
            !matches!(
                element.value().name(),
                "script" | "style" | "noscript" | "template"
            )
        })
        .flat_map(|element| {
            element
                .children()
                .filter_map(|node| node.value().as_text())
                .map(|text| text.to_string())
                .collect::<Vec<_>>()
        })
        .map(|text| normalize_html_text(&text))
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

fn structured_value(document: &Html, labels: &[&str]) -> Option<String> {
    let row_selector = static_selector("tr");
    let cell_selector = static_selector("th, td");
    for row in document.select(&row_selector) {
        let cells = row
            .select(&cell_selector)
            .map(element_text)
            .filter(|text| !text.is_empty())
            .collect::<Vec<_>>();
        for (index, cell) in cells.iter().enumerate() {
            for label in labels {
                if normalized_label(cell) == normalized_label(label) {
                    if let Some(value) = cells.get(index + 1).and_then(|value| public_value(value))
                    {
                        return Some(value);
                    }
                }
                if let Some(value) = inline_labeled_value(cell, label) {
                    return public_value(&value);
                }
            }
        }
    }

    let definition_selector = static_selector("dl");
    let term_selector = static_selector("dt, dd");
    for list in document.select(&definition_selector) {
        let terms = list
            .select(&term_selector)
            .map(element_text)
            .filter(|text| !text.is_empty())
            .collect::<Vec<_>>();
        for pair in terms.windows(2) {
            if labels
                .iter()
                .any(|label| normalized_label(&pair[0]) == normalized_label(label))
            {
                if let Some(value) = public_value(&pair[1]) {
                    return Some(value);
                }
            }
        }
    }

    let labeled_selector = static_selector("[data-label]");
    for element in document.select(&labeled_selector) {
        let label = element.value().attr("data-label").unwrap_or_default();
        if labels
            .iter()
            .any(|candidate| normalized_label(label) == normalized_label(candidate))
        {
            if let Some(value) = public_value(&element_text(element)) {
                return Some(value);
            }
        }
    }

    let inline_selector = static_selector("li, p, div, span");
    for element in document.select(&inline_selector) {
        let text = element_text(element);
        if text.chars().count() > 160 {
            continue;
        }
        for label in labels {
            if let Some(value) = inline_labeled_value(&text, label) {
                if let Some(value) = public_value(&value) {
                    return Some(value);
                }
            }
        }
    }
    None
}

fn inline_labeled_value(text: &str, label: &str) -> Option<String> {
    let text = text.trim();
    let suffix = text.strip_prefix(label)?.trim_start();
    let value = suffix
        .strip_prefix('：')
        .or_else(|| suffix.strip_prefix(':'))?
        .trim();
    (!value.is_empty()).then(|| value.to_owned())
}

fn plan_candidate(document: &Html, aliases: &[&str]) -> Option<String> {
    let selector = static_selector("tr, li, option, label, button, a, div");
    document
        .select(&selector)
        .filter_map(|element| {
            let text = element_text(element);
            let attributes = [
                element.value().attr("class").unwrap_or_default(),
                element.value().attr("id").unwrap_or_default(),
                element.value().attr("name").unwrap_or_default(),
            ]
            .join(" ")
            .to_ascii_lowercase();
            let named_plan_element = ["plan", "vip", "price", "month", "year", "goods"]
                .iter()
                .any(|marker| attributes.contains(marker));
            let explicit_plan_context = [
                "购买",
                "套餐",
                "续费",
                "开通",
                "升级",
                "包月",
                "包年",
                "下载包",
            ]
            .iter()
            .any(|marker| text.contains(marker));
            let has_commercial_detail =
                extract_price(&text).is_some() || extract_discount(&text).is_some();
            (!text.is_empty()
                && text.chars().count() <= 160
                && aliases
                    .iter()
                    .any(|alias| contains_plan_alias(&text, alias))
                && (named_plan_element
                    || explicit_plan_context
                    || has_commercial_detail
                    || element.value().name() == "option")
                && !plan_is_unavailable(element, &text)
                && public_value(&text).is_some())
            .then_some(text)
        })
        .min_by_key(|text| text.chars().count())
}

fn contains_plan_alias(text: &str, alias: &str) -> bool {
    text.match_indices(alias).any(|(index, _)| {
        let before = text[..index].chars().next_back();
        let after = text[index + alias.len()..].chars().next();
        let starts_with_digit = alias
            .chars()
            .next()
            .is_some_and(|value| value.is_ascii_digit());
        let ends_with_digit = alias
            .chars()
            .next_back()
            .is_some_and(|value| value.is_ascii_digit());
        !(starts_with_digit && before.is_some_and(|value| value.is_ascii_digit()))
            && !(ends_with_digit && after.is_some_and(|value| value.is_ascii_digit()))
    })
}

fn plan_is_unavailable(element: ElementRef<'_>, text: &str) -> bool {
    let class = element
        .value()
        .attr("class")
        .unwrap_or_default()
        .to_ascii_lowercase();
    element.value().attr("disabled").is_some()
        || element.value().attr("aria-disabled") == Some("true")
        || ["disabled", "unavailable", "soldout", "offline"]
            .iter()
            .any(|marker| class.contains(marker))
        || [
            "已下架",
            "已停售",
            "停止销售",
            "暂停销售",
            "已售罄",
            "暂未开放",
            "不可购买",
        ]
        .iter()
        .any(|marker| text.contains(marker))
}

static PRICE_PATTERN: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r#"(?:￥|¥)\s*\d+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?\s*元"#)
        .expect("price regex must be valid")
});

fn extract_price(text: &str) -> Option<String> {
    PRICE_PATTERN
        .find(text)
        .map(|value| value.as_str().replace(' ', ""))
}

static DISCOUNT_PATTERN: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"\d+(?:\.\d+)?\s*折"#).expect("discount regex must be valid"));

fn extract_discount(text: &str) -> Option<String> {
    DISCOUNT_PATTERN
        .find(text)
        .map(|value| value.as_str().replace(' ', ""))
}

fn element_text(element: ElementRef<'_>) -> String {
    normalize_html_text(&element.text().collect::<Vec<_>>().join(" "))
}

fn normalize_html_text(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim_matches(&['：', ':', ' ', '\t', '\r', '\n'][..])
        .to_owned()
}

fn normalized_label(value: &str) -> String {
    normalize_html_text(value).replace(' ', "")
}

fn public_value(value: &str) -> Option<String> {
    let value = normalize_html_text(value);
    if value.is_empty() || value.chars().count() > 160 {
        return None;
    }
    let lower = value.to_ascii_lowercase();
    if [
        "cookie",
        "set-cookie",
        "formhash",
        "token",
        "password",
        "passwd",
        "session",
        "authorization",
        "bearer",
    ]
    .iter()
    .any(|marker| lower.contains(marker))
    {
        return None;
    }
    Some(value)
}

fn static_selector(value: &str) -> Selector {
    Selector::parse(value).expect("static HTML selector must be valid")
}

pub fn js_data_fields(html: &str) -> CoreResult<BTreeMap<String, String>> {
    js_data_fields_with_context(html, html)
}

pub fn js_data_fields_with_context(
    html: &str,
    context: &str,
) -> CoreResult<BTreeMap<String, String>> {
    let data_regex = Regex::new(r#"(?s)data\s*[:=]\s*\{([^}]+)\}"#)
        .map_err(|_| CoreError::parse("页面解析规则初始化失败"))?;
    let candidates: Vec<_> = data_regex.captures_iter(html).collect();
    let content = candidates
        .iter()
        .max_by_key(|capture| capture.get(1).map(|item| item.as_str().len()).unwrap_or(0))
        .and_then(|capture| capture.get(1))
        .map(|item| item.as_str())
        .ok_or_else(|| CoreError::parse("页面缺少下载参数"))?;
    let pair_regex = Regex::new(r#"['\"]?([A-Za-z0-9_]+)['\"]?\s*:\s*([^,}]+)"#)
        .map_err(|_| CoreError::parse("页面解析规则初始化失败"))?;
    let mut result = BTreeMap::new();
    for capture in pair_regex.captures_iter(content) {
        let key = capture[1].to_owned();
        let raw = capture[2].trim().trim_matches(&['\'', '"'][..]);
        let value = if raw.chars().all(|ch| ch.is_ascii_digit())
            || capture[2].trim().starts_with(['\'', '"'])
        {
            raw.to_owned()
        } else {
            capture_variable(context, raw).unwrap_or_default()
        };
        result.insert(key, value);
    }
    if result.is_empty() {
        Err(CoreError::parse("页面下载参数为空"))
    } else {
        Ok(result)
    }
}

pub fn formhash(html: &str) -> CoreResult<String> {
    capture(html, r#"name=['\"]formhash['\"]\s+value=['\"]([^'\"]+)"#)
        .ok_or_else(|| CoreError::parse("回收站页面缺少 formhash"))
}

pub fn iframe_path(html: &str) -> Option<String> {
    capture(
        html,
        r#"(?is)<iframe[^>]+src=['\"]([^'\"]*/fn(?:\?|/)[^'\"]*)"#,
    )
    .or_else(|| capture(html, r#"(?is)(?:href|src)=['\"]([^'\"]*/tp/[^'\"]+)"#))
}

pub fn ajax_file_id(html: &str) -> Option<String> {
    capture(html, r#"ajaxm\.php\?file=(\d+)"#)
}

pub fn ajax_endpoint(html: &str) -> Option<String> {
    capture(
        html,
        r#"(?is)url\s*:\s*['\"]([^'\"]*ajaxm\.php(?:\?file=\d+)?)"#,
    )
    .or_else(|| capture(html, r#"(?is)['\"]([^'\"]*ajaxm\.php(?:\?file=\d+)?)['\"]"#))
}

pub fn function_block(html: &str, name: &str) -> Option<String> {
    let pattern = format!(
        r#"(?is)function\s+{}\s*\([^)]*\)\s*\{{"#,
        regex::escape(name)
    );
    let found = Regex::new(&pattern).ok()?.find(html)?;
    let mut depth = 1_usize;
    let rest = &html[found.end()..];
    let bytes = rest.as_bytes();
    let mut offset = 0_usize;
    let mut quote = None;
    let mut line_comment = false;
    let mut block_comment = false;
    while offset < bytes.len() {
        let current = bytes[offset];
        let next = bytes.get(offset + 1).copied();
        if line_comment {
            if matches!(current, b'\n' | b'\r') {
                line_comment = false;
            }
            offset += 1;
            continue;
        }
        if block_comment {
            if current == b'*' && next == Some(b'/') {
                block_comment = false;
                offset += 2;
            } else {
                offset += 1;
            }
            continue;
        }
        if let Some(delimiter) = quote {
            if current == b'\\' {
                offset = (offset + 2).min(bytes.len());
                continue;
            }
            if current == delimiter {
                quote = None;
            }
            offset += 1;
            continue;
        }
        match (current, next) {
            (b'/', Some(b'/')) => {
                line_comment = true;
                offset += 2;
            }
            (b'/', Some(b'*')) => {
                block_comment = true;
                offset += 2;
            }
            (b'\'' | b'"' | b'`', _) => {
                quote = Some(current);
                offset += 1;
            }
            (b'{', _) => {
                depth += 1;
                offset += 1;
            }
            (b'}', _) => {
                depth -= 1;
                if depth == 0 {
                    return Some(html[found.start()..found.end() + offset + 1].to_owned());
                }
                offset += 1;
            }
            _ => offset += 1,
        }
    }
    None
}

pub fn recycle_items(html: &str) -> CoreResult<Vec<CloudItem>> {
    let folder_regex = Regex::new(
        r#"(?is)folder_id=(\d+)[^>]*>[^<]*(?:&nbsp;)?\s*([^<]+?)\.{0,3}</a>.*?<td[^>]*>([^<]*)</td>.*?<td[^>]*>([^<]*)</td>"#,
    )
    .map_err(|_| CoreError::parse("回收站解析规则初始化失败"))?;
    let file_regex = Regex::new(
        r#"(?is)fl_sel_ids[^>]+value=['\"](\d+)['\"].*?filetype/([A-Za-z0-9]+)\.gif.*?/?>\s*([^<]+?)(?:\.{3})?</a>.*?<td[^>]*>([\d\-]+)</td>"#,
    )
    .map_err(|_| CoreError::parse("回收站解析规则初始化失败"))?;
    let mut items = Vec::new();
    for capture in folder_regex.captures_iter(html) {
        let mut item = CloudItem::folder(capture[1].to_owned(), clean_html_text(&capture[2]));
        item.size = Some(clean_html_text(&capture[3]));
        item.modified_at = Some(clean_html_text(&capture[4]));
        item.is_recycle = true;
        items.push(item);
    }
    for capture in file_regex.captures_iter(html) {
        let extension = &capture[2];
        let mut name = clean_html_text(&capture[3]);
        if !name
            .to_ascii_lowercase()
            .ends_with(&format!(".{extension}").to_ascii_lowercase())
        {
            name.push('.');
            name.push_str(extension);
        }
        let mut item = CloudItem::file(capture[1].to_owned(), name);
        item.modified_at = Some(capture[4].to_owned());
        item.is_recycle = true;
        items.push(item);
    }
    Ok(items)
}

fn capture(text: &str, pattern: &str) -> Option<String> {
    Regex::new(pattern)
        .ok()?
        .captures(text)?
        .get(1)
        .map(|value| value.as_str().trim().to_owned())
}

fn capture_variable(html: &str, name: &str) -> Option<String> {
    let pattern = format!(r#"var\s+{}\s*=\s*['\"]?([^;'\"]+)"#, regex::escape(name));
    capture(html, &pattern)
}

fn string_field(value: &Value, key: &str) -> CoreResult<String> {
    optional_string(value, key).ok_or_else(|| CoreError::parse(format!("字段 {key} 缺失")))
}

fn present_string(value: &Value, key: &str, message: &str) -> CoreResult<String> {
    let object = value.as_object().ok_or_else(|| CoreError::parse(message))?;
    present_string_in_object(object, key, message)
}

fn present_string_in_object(
    value: &serde_json::Map<String, Value>,
    key: &str,
    message: &str,
) -> CoreResult<String> {
    value
        .get(key)
        .and_then(value_to_id)
        .ok_or_else(|| CoreError::parse(message))
}

fn value_to_id(value: &Value) -> Option<String> {
    value
        .as_str()
        .map(ToOwned::to_owned)
        .or_else(|| value.as_i64().map(|number| number.to_string()))
}

fn optional_string(value: &Value, key: &str) -> Option<String> {
    let field = value.get(key)?;
    field
        .as_str()
        .map(ToOwned::to_owned)
        .or_else(|| field.as_i64().map(|number| number.to_string()))
}

fn sanitize_message(value: &str) -> String {
    value
        .chars()
        .filter(|character| !character.is_control())
        .take(160)
        .collect()
}

fn absolute_share_url(value: &str) -> String {
    if value.starts_with("http://") || value.starts_with("https://") {
        value.to_owned()
    } else {
        format!("https://pan.lanzoui.com/{}", value.trim_start_matches('/'))
    }
}

fn trusted_icon_url(value: &str) -> Option<String> {
    if value.is_empty() || value.len() > 16 * 1024 || value.contains(['\0', '\r', '\n']) {
        return None;
    }
    let candidate = if value.starts_with("https://") {
        value.to_owned()
    } else if value.contains("://") {
        return None;
    } else {
        format!("https://{}", value.trim_start_matches('/'))
    };
    let parsed = reqwest::Url::parse(&candidate).ok()?;
    if parsed.scheme() != "https"
        || parsed.host_str() != Some("image.dmpdmp.com")
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || !matches!(parsed.port(), None | Some(443))
    {
        return None;
    }
    Some(candidate)
}

fn clean_html_text(value: &str) -> String {
    value
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .trim()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_api_json_maps_expired_cookie() {
        let error = api_json(r#"{"zt":9,"info":"ignored"}"#).unwrap_err();
        assert_eq!(error.code, "session_expired");
    }

    #[test]
    fn test_ensure_session_html_maps_login_page_to_expired() {
        let error = ensure_session_html(
            "<title>\n  用户 登录 \n</title><form><input type=password></form>",
        )
        .unwrap_err();
        assert_eq!(error.code, "session_expired");
    }

    #[test]
    fn test_list_items_parses_folder_and_file_shapes() {
        let folder: Value =
            serde_json::from_str(r#"{"zt":1,"text":[{"fol_id":"7","name":"docs","onof":"1"}]}"#)
                .unwrap();
        let item = &list_items(&folder, true).unwrap()[0];
        assert!(item.is_folder);
        assert_eq!(item.id, "7");
        assert_eq!(item.has_password, Some(true));

        let file: Value = serde_json::from_str(
            r#"{"zt":1,"text":[{"id":"8","name_all":"app.apk","is_ico":"1","ico":"image.dmpdmp.com/icon.png?e=1&s=secret"}]}"#,
        )
        .unwrap();
        let item = &list_items(&file, false).unwrap()[0];
        assert_eq!(item.has_custom_icon, Some(true));
        assert_eq!(
            item.icon_url.as_deref(),
            Some("https://image.dmpdmp.com/icon.png?e=1&s=secret")
        );
    }

    #[test]
    fn test_list_items_parses_p_ico_custom_icon_state() {
        let file: Value = serde_json::from_str(
            r#"{"zt":1,"text":[{"id":"8","name_all":"app.apk","p_ico":1,"ico":"image.dmpdmp.com/icon.png?e=1&s=secret"}]}"#,
        )
        .unwrap();

        let item = &list_items(&file, false).unwrap()[0];

        assert_eq!(item.has_custom_icon, Some(true));
        assert_eq!(
            item.icon_url.as_deref(),
            Some("https://image.dmpdmp.com/icon.png?e=1&s=secret")
        );
    }

    #[test]
    fn test_list_items_rejects_untrusted_custom_icon_host() {
        let file: Value = serde_json::from_str(
            r#"{"zt":1,"text":[{"id":"8","name_all":"app.apk","is_ico":"1","ico":"evil.example/icon.png?signature=x"}]}"#,
        )
        .unwrap();
        let item = &list_items(&file, false).unwrap()[0];
        assert_eq!(item.has_custom_icon, Some(true));
        assert_eq!(item.icon_url, None);
    }

    #[test]
    fn test_managed_file_metadata_distinguishes_empty_from_missing_description() {
        let empty = api_json(r#"{"zt":1,"text":"软件.apk","info":""}"#).unwrap();
        assert_eq!(
            managed_file_metadata(&empty).unwrap(),
            ManagedMetadata {
                name: "软件.apk".to_owned(),
                description: String::new(),
            }
        );

        let missing = api_json(r#"{"zt":1,"text":"软件.apk"}"#).unwrap();
        assert_eq!(
            managed_file_metadata(&missing).unwrap_err().code,
            "parse_error"
        );
    }

    #[test]
    fn test_managed_folder_metadata_requires_real_description_field() {
        let value = api_json(
            r#"{"zt":1,"info":{"name":"软件库","des":"真实简介","new_url":"https://example.invalid"}}"#,
        )
        .unwrap();
        assert_eq!(
            managed_folder_metadata(&value).unwrap(),
            ManagedMetadata {
                name: "软件库".to_owned(),
                description: "真实简介".to_owned(),
            }
        );
        let missing = api_json(r#"{"zt":1,"info":{"name":"软件库"}}"#).unwrap();
        assert!(managed_folder_metadata(&missing).is_err());
    }

    #[test]
    fn test_upload_file_id_accepts_openlist_shape_and_rejects_invalid_id() {
        assert_eq!(
            upload_file_id(&serde_json::json!({"text": [{"id": "901"}]})).unwrap(),
            Some("901".to_owned())
        );
        assert_eq!(
            upload_file_id(&serde_json::json!({"text": [{"id": 902}]})).unwrap(),
            Some("902".to_owned())
        );
        assert_eq!(
            upload_file_id(&serde_json::json!({"text": [{}]})).unwrap(),
            None
        );
        assert!(upload_file_id(&serde_json::json!({"text": [{"id": []}]})).is_err());
    }

    #[test]
    fn test_js_data_fields_resolves_variables() {
        let html = r#"var sg='token'; data: {'action':'downprocess','sign':sg,'ves':1}"#;
        let fields = js_data_fields(html).unwrap();
        assert_eq!(fields["sign"], "token");
        assert_eq!(fields["ves"], "1");
    }

    #[test]
    fn test_function_block_ignores_other_page_data() {
        let html = r#"function other(){data:{'bad':'x'}} function down_p(){if(true){data:{'action':'downprocess','sign':'ok'}}}"#;
        let block = function_block(html, "down_p").unwrap();
        assert!(!block.contains("'bad'"));
        assert_eq!(js_data_fields(&block).unwrap()["sign"], "ok");
    }

    #[test]
    fn test_function_block_ignores_braces_inside_javascript_strings() {
        let html = r#"function down_p(){var template='}'; var quoted="{ignored}"; /* } */ data:{'action':'downprocess','sign':'ok'} // }
        } function after(){data:{'bad':'x'}}"#;
        let block = function_block(html, "down_p").unwrap();
        assert!(block.contains("'sign':'ok'"));
        assert!(!block.contains("function after"));
    }

    #[test]
    fn test_iframe_path_uses_only_download_jump_routes() {
        let html = r#"<iframe src='/ad/banner'></iframe><iframe src='/fn?token=one'></iframe>"#;
        assert_eq!(iframe_path(html).as_deref(), Some("/fn?token=one"));
        assert_eq!(iframe_path("<iframe src='/ad/banner'></iframe>"), None);
        assert_eq!(
            iframe_path(r#"<a href='/tp/share-token'>download</a>"#).as_deref(),
            Some("/tp/share-token")
        );
    }

    #[test]
    fn test_recycle_items_normalizes_folder_and_file() {
        let html = r#"
          <a href="?folder_id=42">&nbsp;docs...</a><td>1 MB</td><td>2026-07-01</td>
          <input name="fl_sel_ids[]" value="7"><img src="filetype/txt.gif" /> report</a><td>2026-07-02</td>
        "#;
        let items = recycle_items(html).unwrap();
        assert_eq!(items.len(), 2);
        assert!(items.iter().all(|item| item.is_recycle));
        assert_eq!(items[0].id, "42");
        assert_eq!(items[1].name, "report.txt");
    }

    #[test]
    fn test_account_surface_parses_vip_profile_plans_and_public_facts() {
        let mypower = r#"
          <html><body>
            <nav>
              <a>我的权限</a><a>财务充值</a><a>文件升级</a><a>下载提现</a>
              <a>提现记录</a><a>邀请注册</a>
            </nav>
            <table>
              <tr><th>会员状态</th><td>VIP会员</td></tr>
              <tr><th>会员等级</th><td>VIP 2</td></tr>
              <tr><th>会员到期</th><td>2099年8月1日</td></tr>
              <tr><th>存储空间</th><td>3 TB</td></tr>
              <tr><th>单个文件大小</th><td>220 MB</td></tr>
            </table>
            <section>密码修改 手机号 注销账户</section>
          </body></html>
        "#;
        let huiyuan = r#"
          <html><body>
            <div class="plan">1个月 ￥12</div>
            <div class="plan">2个月 20元</div>
            <div class="plan">6个月 9折 ￥54</div>
            <div class="plan">1年 8折 96元</div>
            <div>包月 包年 下载包</div>
            <ul><li>免广告下载</li><li>搜索</li><li>直链域名绑定</li></ul>
          </body></html>
        "#;

        let value = account_surface(mypower, huiyuan).unwrap();

        assert_eq!(value["membershipProfile"]["state"], "vip");
        assert_eq!(value["membershipProfile"]["level"], "VIP 2");
        assert_eq!(value["membershipProfile"]["expiresAt"], "2099-08-01");
        assert!(value["facts"].as_array().unwrap().iter().any(|fact| {
            fact["id"] == "storageCapacity" && fact["known"] == true && fact["value"] == "3 TB"
        }));
        assert!(value["plans"].as_array().unwrap().iter().any(|plan| {
            plan["id"] == "month6"
                && plan["priceLabel"] == "￥54"
                && plan["detail"].as_str().unwrap().contains("9折")
        }));
    }

    #[test]
    fn test_account_surface_distinguishes_free_and_unknown_without_purchase_inference() {
        let free = account_surface(
            "<table><tr><th>账号级别</th><td>免费用户</td></tr></table>",
            "<div>会员增值服务 包月 包年 下载包</div>",
        )
        .unwrap();
        assert_eq!(free["membershipProfile"]["state"], "free");

        let unknown = account_surface(
            "<div>我的权限 财务充值 文件升级 下载提现 提现记录 邀请注册 密码修改 手机号 注销账户</div>",
            "<div>购买会员 会员增值服务 1个月 10元 包月 包年 下载包</div>",
        )
        .unwrap();
        assert_eq!(unknown["membershipProfile"]["state"], "unknown");
    }

    #[test]
    fn test_account_surface_marks_expired_membership_as_free() {
        let expired_by_date = account_surface(
            "<table><tr><th>会员状态</th><td>VIP会员</td></tr><tr><th>会员到期</th><td>2000-01-01</td></tr></table>",
            "<div>会员增值服务</div>",
        )
        .unwrap();
        assert_eq!(expired_by_date["membershipProfile"]["state"], "free");
        assert_eq!(
            expired_by_date["membershipProfile"]["displayName"],
            "会员已过期"
        );

        let expired_by_label = account_surface(
            "<table><tr><th>会员状态</th><td>VIP会员已过期</td></tr></table>",
            "<div>会员增值服务</div>",
        )
        .unwrap();
        assert_eq!(expired_by_label["membershipProfile"]["state"], "free");
    }

    #[test]
    fn test_membership_plans_reject_numeric_substrings_and_unavailable_offers() {
        let value = account_surface(
            "<table><tr><th>账号级别</th><td>免费用户</td></tr></table>",
            r#"
              <div class="plan">11月套餐 ￥110</div>
              <button class="plan" disabled>1个月套餐 ￥10</button>
              <div class="plan">2个月套餐已下架 ￥18</div>
              <div class="plan">6个月套餐 ￥48</div>
            "#,
        )
        .unwrap();
        let plans = value["plans"].as_array().unwrap();
        let availability = |id: &str| {
            plans.iter().find(|plan| plan["id"] == id).unwrap()["available"]
                .as_bool()
                .unwrap()
        };
        assert!(!availability("month1"));
        assert!(!availability("month2"));
        assert!(availability("month6"));
    }

    #[test]
    fn test_account_surface_returns_all_entry_and_personalization_ids_without_secrets() {
        let mypower = r#"
          <nav>我的权限 财务充值 文件升级 下载提现 提现记录 邀请注册</nav>
          <div>密码修改 手机号 注销账户</div>
          <table>
            <tr><th>云存储统计</th><td>cookie=private</td></tr>
            <tr><th>下载速度</th><td>高速</td></tr>
          </table>
          <input name="formhash" value="private-formhash">
        "#;
        let huiyuan = r#"
          <div>
            免广告下载 上传时间隐藏/显示 子文件夹 搜索 新文件密码默认开关
            头像上传 下载页模板 发布者昵称 日下载报表 文件保存时间 直链域名绑定
          </div>
          <script>var token='private-token';</script>
        "#;

        let value = account_surface(mypower, huiyuan).unwrap();
        let entry_ids = value["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["id"].as_str().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(
            entry_ids,
            [
                "permissions",
                "balance",
                "fileUpgrade",
                "downloadCashout",
                "cashoutRecords",
                "invite",
                "password",
                "phone",
                "closeAccount",
            ]
        );
        assert_eq!(value["personalization"].as_array().unwrap().len(), 11);
        assert!(value["personalization"]
            .as_array()
            .unwrap()
            .iter()
            .all(|item| item["writable"] == false));
        let serialized = value.to_string().to_ascii_lowercase();
        assert!(!serialized.contains("private"));
        assert!(!serialized.contains("formhash"));
        assert!(!serialized.contains("token"));
        assert!(!serialized.contains("cookie"));
    }
}
