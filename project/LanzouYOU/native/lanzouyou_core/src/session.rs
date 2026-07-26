use std::{
    collections::{BTreeMap, HashSet},
    path::Path,
};

use reqwest::header::LOCATION;
use serde_json::{json, Value};

use crate::{
    error::{CoreError, CoreResult},
    http_client::{merge_cookie_headers, response_cookies, HttpClient},
    model::{CloudItem, ManagedMetadata, ShareRecord},
    parser, validation,
};

pub struct SessionClient {
    pub(crate) http: HttpClient,
    pub(crate) cookie: String,
    pub(crate) uid: String,
    pub(crate) vei: String,
}

impl SessionClient {
    pub fn new() -> CoreResult<Self> {
        Ok(Self {
            http: HttpClient::new()?,
            cookie: String::new(),
            uid: String::new(),
            vei: String::new(),
        })
    }

    #[cfg(test)]
    pub fn for_test(base: String) -> CoreResult<Self> {
        Ok(Self {
            http: HttpClient::for_test(base)?,
            cookie: String::new(),
            uid: String::new(),
            vei: String::new(),
        })
    }

    pub fn login(&mut self, account: &str, password: &str) -> CoreResult<Value> {
        validation::required(account, "account", 128)?;
        validation::required(password, "password", 256)?;
        let form = map(&[
            ("task", "3"),
            ("uid", account),
            ("pwd", password),
            ("setSessionId", ""),
            ("setSig", ""),
            ("setScene", ""),
            ("setTocen", ""),
            ("formhash", ""),
        ]);
        let url = format!("{}/mlogin.php", self.http.bases.up);
        self.http.get(&url, "", &[])?;
        let login_url = format!("{url}?istoken=3");
        let response = self.http.post_form_no_redirect(&login_url, "", &form)?;
        parser::api_json(response.text()?)?;
        let response_cookie = response_cookies(&response.headers);
        let cookie =
            merge_cookie_headers(&response_cookie, &self.http.cookies_for_url(&login_url)?);
        if cookie.is_empty() {
            return Err(CoreError::remote("登录成功但未收到会话 cookie", false));
        }
        self.cookie = cookie;
        if let Err(error) = self.bootstrap() {
            self.clear();
            return Err(error);
        }
        Ok(json!({"cookie": self.cookie, "authenticated": true}))
    }

    pub fn restore(&mut self, cookie: &str) -> CoreResult<Value> {
        validation::cookie(cookie)?;
        self.cookie = cookie.trim().to_owned();
        if let Err(error) = self.bootstrap() {
            self.clear();
            return Err(error);
        }
        Ok(json!({"cookie": self.cookie, "authenticated": true}))
    }

    pub fn logout(&mut self) -> CoreResult<Value> {
        if self.cookie.is_empty() {
            self.clear();
            return Ok(json!({"authenticated": false}));
        }
        let url = format!("{}/account.php", self.http.bases.pc);
        let result = self.http.get(
            &url,
            &self.cookie,
            &[("action".to_owned(), "logout".to_owned())],
        );
        self.clear();
        result?;
        Ok(json!({"authenticated": false}))
    }

    pub fn session_info(&self) -> Value {
        json!({
            "authenticated": !self.cookie.is_empty() && !self.uid.is_empty(),
            "userId": if self.uid.is_empty() { Value::Null } else { Value::String(self.uid.clone()) }
        })
    }

    pub fn account_capabilities(&self) -> CoreResult<Value> {
        self.require_session()?;
        Ok(json!({
            "authenticated": true,
            "userId": self.uid,
            "accountPortalUrl": "https://pc.woozooo.com/mydisk.php?item=profile&action=mypower",
            "accountFeatures": [
                "个性域名", "增值服务", "密码修改", "手机号", "注销账户",
                "单个文件大小", "云存储统计", "下载免登录", "下载速度",
                "下载次数", "下载流量", "存储空间", "允许上传类型"
            ],
            "membership": {
                "state": "available",
                "portalUrl": "https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan",
                "reason": "蓝奏云官方页面可查看套餐并完成开通或续费；付款必须由用户在官方页面确认",
                "readable": false,
                "writable": false,
                "features": ["续费/升级", "选择购买时长", "包月", "包年", "下载包"]
            },
            "personalization": {
                "state": "available",
                "portalUrl": "https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan",
                "readable": false,
                "writable": false,
                "reason": "蓝奏云官方页面提供这些会员设置；当前未验证稳定且安全的直接读写接口",
                "features": [
                    "免广告下载", "上传时间隐藏/显示", "子文件夹", "搜索",
                    "新文件密码默认开关", "头像上传", "下载页模板", "发布者昵称",
                    "日下载报表", "文件保存时间", "直链域名绑定"
                ]
            },
            "acceptsPaymentData": false
        }))
    }

    fn bootstrap(&mut self) -> CoreResult<()> {
        let url = format!("{}/mydisk.php", self.http.bases.pc);
        let response = self.http.get(
            &url,
            &self.cookie,
            &[
                ("item".to_owned(), "files".to_owned()),
                ("action".to_owned(), "index".to_owned()),
            ],
        )?;
        let (uid, vei) = parser::bootstrap_values(response.text()?)?;
        self.uid = uid;
        self.vei = vei;
        Ok(())
    }

    pub fn list(&self, folder_id: &str, page: u32, page_size: u32) -> CoreResult<Value> {
        self.require_session()?;
        validation::id(folder_id, "folderId")?;
        if page == 0 || page > 10_000 {
            return Err(CoreError::invalid("page 必须在 1..10000"));
        }
        if !(1..=200).contains(&page_size) {
            return Err(CoreError::invalid("pageSize 必须在 1..200"));
        }
        let mut items = Vec::new();
        if page == 1 {
            let folders = self.task(map(&[("task", "47"), ("folder_id", folder_id)]))?;
            items.extend(parser::list_items(&folders, true)?);
        }
        let page_text = page.to_string();
        let files = self.task(map(&[
            ("task", "5"),
            ("folder_id", folder_id),
            ("pg", &page_text),
        ]))?;
        let file_items = parser::list_items(&files, false)?;
        let has_more = files
            .get("info")
            .and_then(parser::value_as_i64)
            .map(|value| value != 0)
            .unwrap_or(!file_items.is_empty());
        items.extend(file_items);
        Ok(json!({
            "items": items,
            "page": page,
            "pageSize": page_size,
            "hasMore": has_more
        }))
    }

    pub(crate) fn list_all(&self, folder_id: &str) -> CoreResult<Vec<CloudItem>> {
        let mut page = 1;
        let mut items = Vec::new();
        loop {
            let result = self.list(folder_id, page, 50)?;
            let mut current: Vec<CloudItem> = serde_json::from_value(result["items"].clone())
                .map_err(|_| CoreError::parse("内部列表转换失败"))?;
            let has_more = result["hasMore"].as_bool().unwrap_or(false);
            items.append(&mut current);
            if !has_more || page >= 10_000 {
                break;
            }
            page += 1;
        }
        Ok(items)
    }

    pub fn move_targets(&self) -> CoreResult<Value> {
        let value = self.task(map(&[("task", "19"), ("file_id", "-1")]))?;
        Ok(json!({"items": parser::move_targets(&value)?}))
    }

    pub fn mkdir(&self, parent_id: &str, name: &str, description: &str) -> CoreResult<Value> {
        let id = self.mkdir_id(parent_id, name, description)?;
        Ok(json!({"id": id, "name": name, "parentId": parent_id}))
    }

    pub(crate) fn mkdir_id(
        &self,
        parent_id: &str,
        name: &str,
        description: &str,
    ) -> CoreResult<String> {
        validation::id(parent_id, "parentId")?;
        validation::required(name, "name", 255)?;
        validation::required(description, "description", 4000).or_else(|error| {
            if description.is_empty() {
                Ok(())
            } else {
                Err(error)
            }
        })?;
        let before = matching_folder_ids(self.list_all(parent_id)?, name);
        let value = self.task(map(&[
            ("task", "2"),
            ("parent_id", parent_id),
            ("folder_name", name),
            ("folder_description", description),
        ]))?;
        if let Some(id) = value.get("text").and_then(value_to_string) {
            if id != "-1" && validation::id(&id, "createdFolderId").is_ok() {
                return Ok(id);
            }
        }
        let after = matching_folder_ids(self.list_all(parent_id)?, name);
        unique_created_folder_id(&before, &after)
    }

    pub fn rename(&self, id: &str, is_folder: bool, name: &str) -> CoreResult<Value> {
        validation::id(id, "id")?;
        validation::required(name, "name", 255)?;
        if is_folder {
            let share = self.share_record(id, true)?;
            self.task(map(&[
                ("task", "4"),
                ("folder_id", id),
                ("folder_name", name),
                ("folder_description", &share.description),
            ]))?;
        } else {
            let file_name = file_rename_stem(name);
            validation::required(file_name, "name", 255)?;
            self.task(map(&[
                ("task", "46"),
                ("file_id", id),
                ("file_name", file_name),
                ("type", "2"),
            ]))?;
        }
        Ok(json!({"id": id, "name": name, "isFolder": is_folder}))
    }

    pub fn delete(&self, id: &str, is_folder: bool) -> CoreResult<Value> {
        validation::id(id, "id")?;
        let form = if is_folder {
            map(&[("task", "3"), ("folder_id", id)])
        } else {
            map(&[("task", "6"), ("file_id", id)])
        };
        self.task(form)?;
        Ok(json!({"id": id, "isFolder": is_folder, "inRecycle": true}))
    }

    pub fn set_password(&self, id: &str, is_folder: bool, password: &str) -> CoreResult<Value> {
        validation::id(id, "id")?;
        if password.chars().count() > 12 || password.contains(['\r', '\n', '\0']) {
            return Err(CoreError::invalid("password 长度必须不超过 12"));
        }
        let enabled = if password.is_empty() { "0" } else { "1" };
        let form = if is_folder {
            map(&[
                ("task", "16"),
                ("folder_id", id),
                ("shows", enabled),
                ("shownames", password),
            ])
        } else {
            if !password.is_empty() && !(2..=6).contains(&password.chars().count()) {
                return Err(CoreError::invalid("文件提取码长度必须为 2..6"));
            }
            map(&[
                ("task", "23"),
                ("file_id", id),
                ("shows", enabled),
                ("shownames", password),
            ])
        };
        self.task(form)?;
        Ok(json!({"id": id, "isFolder": is_folder, "enabled": !password.is_empty()}))
    }

    pub fn set_description(
        &self,
        id: &str,
        is_folder: bool,
        description: &str,
    ) -> CoreResult<Value> {
        validation::id(id, "id")?;
        if description.chars().count() > 4000 || description.contains('\0') {
            return Err(CoreError::invalid("description 过长或包含非法字符"));
        }
        if is_folder {
            let share = self.share_record(id, true)?;
            self.task(map(&[
                ("task", "4"),
                ("folder_id", id),
                ("folder_name", &share.name),
                ("folder_description", description),
            ]))?;
        } else {
            self.task(map(&[
                ("task", "11"),
                ("file_id", id),
                ("desc", description),
            ]))?;
        }
        Ok(json!({"id": id, "isFolder": is_folder, "description": description}))
    }

    pub(crate) fn move_file(&self, id: &str, target_id: &str) -> CoreResult<()> {
        self.task(map(&[
            ("task", "20"),
            ("file_id", id),
            ("folder_id", target_id),
        ]))?;
        Ok(())
    }

    pub(crate) fn share_record(&self, id: &str, is_folder: bool) -> CoreResult<ShareRecord> {
        validation::id(id, "id")?;
        let value = if is_folder {
            self.task(map(&[("task", "18"), ("folder_id", id)]))?
        } else {
            self.task(map(&[("task", "22"), ("file_id", id)]))?
        };
        let mut record = parser::share_record(&value, is_folder)?;
        if !is_folder {
            let info = self.task(map(&[("task", "12"), ("file_id", id)]))?;
            let metadata = parser::managed_file_metadata(&info)?;
            record.name = metadata.name;
            record.description = metadata.description;
        }
        Ok(record)
    }

    pub(crate) fn managed_metadata(
        &self,
        id: &str,
        is_folder: bool,
    ) -> CoreResult<ManagedMetadata> {
        validation::id(id, "id")?;
        let value = if is_folder {
            self.task(map(&[("task", "18"), ("folder_id", id)]))?
        } else {
            self.task(map(&[("task", "12"), ("file_id", id)]))?
        };
        if is_folder {
            parser::managed_folder_metadata(&value)
        } else {
            parser::managed_file_metadata(&value)
        }
    }

    pub fn get_description(&self, id: &str, is_folder: bool) -> CoreResult<Value> {
        let metadata = self.managed_metadata(id, is_folder)?;
        Ok(json!({
            "id": id,
            "isFolder": is_folder,
            "name": metadata.name,
            "description": metadata.description,
        }))
    }

    pub fn share_info(&self, id: &str, is_folder: bool) -> CoreResult<Value> {
        let record = self.share_record(id, is_folder)?;
        let direct_url = if is_folder {
            None
        } else {
            // Sharing metadata remains useful when a public download host
            // temporarily rejects direct-link resolution. Download performs
            // the same resolution as a required operation and still reports
            // that failure to its caller.
            self.resolve_direct_url(&record.url, &record.password).ok()
        };
        Ok(json!({
            "id": id,
            "isFolder": is_folder,
            "name": record.name,
            "shareUrl": record.url,
            "password": record.password,
            "description": record.description,
            "directUrl": direct_url
        }))
    }

    pub(crate) fn resolve_direct_url(&self, share_url: &str, password: &str) -> CoreResult<String> {
        let first = self
            .http
            .get(share_url, "", &[])
            .map_err(|error| download_stage("打开分享页", error))?;
        let first_html = first.text()?;
        if first_html.contains("文件不存在") || first_html.contains("取消分享") {
            return Err(CoreError::new("not_found", "分享文件不存在或已取消", false));
        }
        let (page_url, page_html) = if let Some(path) = parser::iframe_path(first_html) {
            let joined = reqwest::Url::parse(share_url)
                .and_then(|base| base.join(&path))
                .map_err(|_| CoreError::parse("下载页地址无效"))?;
            let response = self
                .http
                .get(joined.as_str(), "", &[])
                .map_err(|error| download_stage("打开跳转页", error))?;
            (joined.to_string(), response.text()?.to_owned())
        } else {
            (share_url.to_owned(), first_html.to_owned())
        };
        let parameter_source = if page_html.contains("pwdload") || page_html.contains("passwddiv") {
            parser::function_block(&page_html, "down_p").unwrap_or_else(|| page_html.clone())
        } else {
            page_html.clone()
        };
        let mut fields = parser::js_data_fields_with_context(&parameter_source, &page_html)?;
        if !password.is_empty() {
            fields.insert("p".to_owned(), password.to_owned());
        }
        let ajax_path = parser::ajax_endpoint(&parameter_source)
            .or_else(|| parser::ajax_endpoint(&page_html))
            .or_else(|| parser::ajax_endpoint(first_html))
            .or_else(|| {
                parser::ajax_file_id(&page_html)
                    .or_else(|| parser::ajax_file_id(first_html))
                    .map(|file_id| format!("/ajaxm.php?file={file_id}"))
            })
            .ok_or_else(|| CoreError::parse("下载页缺少 AJAX 地址"))?;
        let ajax_url = reqwest::Url::parse(&page_url)
            .and_then(|base| base.join(&ajax_path))
            .map_err(|_| CoreError::parse("下载接口地址无效"))?
            .to_string();
        let ajax = self
            .http
            .post_form_ajax(&ajax_url, "", &fields, &page_url)
            .map_err(|error| download_stage("获取下载地址", error))?;
        let value: Value = serde_json::from_str(ajax.text()?)
            .map_err(|_| CoreError::parse("下载接口返回无效 JSON"))?;
        let domain = value
            .get("dom")
            .and_then(Value::as_str)
            .ok_or_else(|| CoreError::parse("下载接口缺少 dom"))?;
        let path = value
            .get("url")
            .and_then(Value::as_str)
            .ok_or_else(|| CoreError::parse("下载接口缺少 url"))?;
        let (download_base, intermediate) = download_location(domain, path, &page_url)?;
        let redirected = self
            .http
            .get_no_redirect_with_referer(&intermediate, "down_ip=1", &[], &download_base)
            .map_err(|error| download_stage("打开下载验证页", error))?;
        if (300..400).contains(&redirected.status) {
            let location = redirected
                .headers
                .get(LOCATION)
                .and_then(|value| value.to_str().ok())
                .ok_or_else(|| CoreError::parse("下载重定向缺少 Location"));
            return absolute_http_location(&intermediate, location?);
        }
        let challenge = redirected.text()?;
        let mut secondary = parser::js_data_fields(challenge)?;
        secondary.insert("el".to_owned(), "2".to_owned());
        let verify_url = format!("{download_base}/ajax.php");
        wait_secondary_verification();
        let response = self
            .http
            .post_form_ajax(&verify_url, "down_ip=1", &secondary, &intermediate)
            .map_err(|error| download_stage("提交下载验证", error))?;
        let value: Value = serde_json::from_str(response.text()?)
            .map_err(|_| CoreError::parse("二次下载验证返回无效 JSON"))?;
        let direct = value
            .get("url")
            .and_then(Value::as_str)
            .ok_or_else(|| CoreError::parse("二次下载验证缺少直链"))?;
        let direct = reqwest::Url::parse(direct)
            .map_err(|_| CoreError::parse("二次下载验证尚未返回有效直链"))?;
        if !matches!(direct.scheme(), "http" | "https") || direct.host_str().is_none() {
            return Err(CoreError::parse("二次下载验证返回了不受信任的地址"));
        }
        Ok(direct.to_string())
    }

    pub fn recycle_list(&self) -> CoreResult<Value> {
        self.require_session()?;
        let url = format!("{}/mydisk.php", self.http.bases.pc);
        let response = self.http.get(
            &url,
            &self.cookie,
            &[
                ("item".to_owned(), "recycle".to_owned()),
                ("action".to_owned(), "files".to_owned()),
            ],
        )?;
        let html = response.text()?;
        parser::ensure_session_html(html)?;
        Ok(json!({"items": parser::recycle_items(html)?}))
    }

    pub fn recycle_action(&self, id: &str, is_folder: bool, purge: bool) -> CoreResult<Value> {
        validation::id(id, "id")?;
        let action = match (purge, is_folder) {
            (false, false) => "file_restore",
            (false, true) => "folder_restore",
            (true, false) => "file_delete_complete",
            (true, true) => "folder_delete_complete",
        };
        let id_key = if is_folder { "folder_id" } else { "file_id" };
        self.recycle_form(action, &[(id_key, id)])?;
        Ok(json!({"id": id, "isFolder": is_folder, "purged": purge, "restored": !purge}))
    }

    pub fn recycle_empty(&self) -> CoreResult<Value> {
        self.recycle_form("delete_all", &[])?;
        Ok(json!({"emptied": true}))
    }

    fn recycle_form(&self, action: &str, fields: &[(&str, &str)]) -> CoreResult<()> {
        self.require_session()?;
        let url = format!("{}/mydisk.php", self.http.bases.pc);
        let mut query = vec![
            ("item".to_owned(), "recycle".to_owned()),
            ("action".to_owned(), action.to_owned()),
        ];
        for (key, value) in fields {
            query.push(((*key).to_owned(), (*value).to_owned()));
        }
        let first = self.http.get(&url, &self.cookie, &query)?;
        let first_html = first.text()?;
        parser::ensure_session_html(first_html)?;
        let hash = parser::formhash(first_html)?;
        let mut form = map(&[("action", action), ("task", action), ("formhash", &hash)]);
        for (key, value) in fields {
            form.insert((*key).to_owned(), (*value).to_owned());
        }
        let post_url = format!("{url}?item=recycle");
        let response = self.http.post_form(&post_url, &self.cookie, &form)?;
        let text = response.text()?;
        parser::ensure_session_html(text)?;
        let success = match action {
            "delete_all" => text.contains("清空回收站成功") || text.contains("成功"),
            value if value.contains("restore") => {
                text.contains("恢复成功") || text.contains("还原成功")
            }
            _ => text.contains("删除成功") || text.contains("成功"),
        };
        if success {
            Ok(())
        } else {
            Err(CoreError::remote("回收站操作失败", false))
        }
    }

    pub(crate) fn task(&self, form: BTreeMap<String, String>) -> CoreResult<Value> {
        self.task_with_cookie(form, &self.cookie)
    }

    pub(crate) fn task_with_cookie(
        &self,
        form: BTreeMap<String, String>,
        cookie: &str,
    ) -> CoreResult<Value> {
        self.require_session()?;
        let response = self.http.post_form(&self.task_url(), cookie, &form)?;
        parser::api_json(response.text()?)
    }

    pub(crate) fn task_raw_with_cookie(
        &self,
        form: BTreeMap<String, String>,
        cookie: &str,
    ) -> CoreResult<Value> {
        self.require_session()?;
        let response = self.http.post_form(&self.task_url(), cookie, &form)?;
        serde_json::from_str(response.text()?)
            .map_err(|_| CoreError::parse("蓝奏云返回了无法识别的数据"))
    }

    fn task_url(&self) -> String {
        format!(
            "{}/doupload.php?uid={}&vei={}",
            self.http.bases.pc,
            encode_component(&self.uid),
            encode_component(&self.vei)
        )
    }

    pub(crate) fn require_session(&self) -> CoreResult<()> {
        if self.cookie.is_empty() || self.uid.is_empty() {
            Err(CoreError::unauthenticated())
        } else {
            Ok(())
        }
    }

    pub(crate) fn clear(&mut self) {
        self.cookie.clear();
        self.uid.clear();
        self.vei.clear();
    }

    pub(crate) fn validate_destination(path: &Path) -> CoreResult<()> {
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)?;
            }
        }
        Ok(())
    }
}

fn matching_folder_ids(items: Vec<CloudItem>, name: &str) -> HashSet<String> {
    items
        .into_iter()
        .filter(|item| item.is_folder && item.name == name)
        .map(|item| item.id)
        .collect()
}

fn unique_created_folder_id(
    before: &HashSet<String>,
    after: &HashSet<String>,
) -> CoreResult<String> {
    let mut created = after.difference(before);
    let id = created.next().cloned();
    if id.is_some() && created.next().is_none() {
        return Ok(id.expect("checked some"));
    }
    Err(CoreError::new(
        "missing_created_folder_id",
        "目录已提交创建，但无法安全确认唯一的新目录 ID",
        false,
    ))
}

pub(crate) fn map(values: &[(&str, &str)]) -> BTreeMap<String, String> {
    values
        .iter()
        .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
        .collect()
}

fn value_to_string(value: &Value) -> Option<String> {
    value
        .as_str()
        .map(ToOwned::to_owned)
        .or_else(|| value.as_i64().map(|number| number.to_string()))
}

fn file_rename_stem(name: &str) -> &str {
    name.rsplit_once('.')
        .filter(|(stem, extension)| !stem.is_empty() && !extension.is_empty())
        .map_or(name, |(stem, _)| stem)
}

fn encode_component(value: &str) -> String {
    value
        .bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
                (byte as char).to_string()
            } else {
                format!("%{byte:02X}")
            }
        })
        .collect()
}

fn download_stage(stage: &str, error: CoreError) -> CoreError {
    CoreError::new(
        error.code,
        format!("{stage}失败: {}", error.message),
        error.retriable,
    )
}

fn download_location(domain: &str, path: &str, page_url: &str) -> CoreResult<(String, String)> {
    let page = reqwest::Url::parse(page_url).map_err(|_| CoreError::parse("下载页地址无效"))?;
    let raw_domain = domain.trim();
    if raw_domain.is_empty() {
        return Err(CoreError::parse("下载接口缺少有效域名"));
    }
    let domain_url = if raw_domain.starts_with("//") {
        page.join(raw_domain)
    } else if raw_domain.contains("://") {
        reqwest::Url::parse(raw_domain)
    } else {
        reqwest::Url::parse(&format!("{}://{raw_domain}", page.scheme()))
    }
    .map_err(|_| CoreError::parse("下载接口域名无效"))?;
    if !matches!(domain_url.scheme(), "http" | "https") || domain_url.host_str().is_none() {
        return Err(CoreError::parse("下载接口域名不受信任"));
    }
    let download_base = format!("{}/file", domain_url.as_str().trim_end_matches('/'));
    let raw_path = path.trim();
    if raw_path.is_empty() {
        return Err(CoreError::parse("下载接口缺少文件路径"));
    }
    let intermediate = if raw_path.starts_with("//") {
        page.join(raw_path)
    } else if raw_path.contains("://") {
        reqwest::Url::parse(raw_path)
    } else {
        reqwest::Url::parse(&format!(
            "{}/{}",
            download_base.trim_end_matches('/'),
            raw_path.trim_start_matches('/')
        ))
    }
    .map_err(|_| CoreError::parse("下载文件地址无效"))?;
    if !matches!(intermediate.scheme(), "http" | "https") || intermediate.host_str().is_none() {
        return Err(CoreError::parse("下载文件地址不受信任"));
    }
    Ok((download_base, intermediate.to_string()))
}

fn absolute_http_location(base: &str, value: &str) -> CoreResult<String> {
    let resolved = reqwest::Url::parse(base)
        .and_then(|base| base.join(value.trim()))
        .map_err(|_| CoreError::parse("下载重定向地址无效"))?;
    if !matches!(resolved.scheme(), "http" | "https") || resolved.host_str().is_none() {
        return Err(CoreError::parse("下载重定向地址不受信任"));
    }
    Ok(resolved.to_string())
}

#[cfg(not(test))]
fn wait_secondary_verification() {
    std::thread::sleep(std::time::Duration::from_millis(3_300));
}

#[cfg(test)]
fn wait_secondary_verification() {}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::TcpListener,
    };

    use super::*;

    #[test]
    fn test_created_folder_id_uses_exact_set_difference_never_existing_name() {
        let before = std::collections::HashSet::from(["10".to_owned()]);
        let after = std::collections::HashSet::from(["10".to_owned(), "11".to_owned()]);
        assert_eq!(unique_created_folder_id(&before, &after).unwrap(), "11");

        assert_eq!(
            unique_created_folder_id(&before, &before).unwrap_err().code,
            "missing_created_folder_id"
        );
        let ambiguous =
            std::collections::HashSet::from(["10".to_owned(), "11".to_owned(), "12".to_owned()]);
        assert_eq!(
            unique_created_folder_id(&before, &ambiguous)
                .unwrap_err()
                .code,
            "missing_created_folder_id"
        );
    }

    #[test]
    fn test_download_location_accepts_protocol_relative_domain() {
        let (base, intermediate) = download_location(
            "//cdn.example.test",
            "/signed/path",
            "https://share.example.test/fn?x=1",
        )
        .unwrap();
        assert_eq!(base, "https://cdn.example.test/file");
        assert_eq!(intermediate, "https://cdn.example.test/file/signed/path");
    }

    #[test]
    fn test_download_location_keeps_absolute_path() {
        let (base, intermediate) = download_location(
            "https://cdn.example.test",
            "https://download.example.test/signed/path",
            "https://share.example.test/fn?x=1",
        )
        .unwrap();
        assert_eq!(base, "https://cdn.example.test/file");
        assert_eq!(intermediate, "https://download.example.test/signed/path");
    }

    #[test]
    fn test_account_capabilities_exposes_no_cookie_or_payment_input() {
        let mut session = SessionClient::for_test("http://127.0.0.1:9".to_owned()).unwrap();
        session.cookie = "private-session-cookie".to_owned();
        session.uid = "101".to_owned();
        session.vei = "202".to_owned();

        let value = session.account_capabilities().unwrap();

        assert_eq!(
            value["accountPortalUrl"],
            "https://pc.woozooo.com/mydisk.php?item=profile&action=mypower"
        );
        assert_eq!(value["membership"]["state"], "available");
        assert_eq!(
            value["membership"]["portalUrl"],
            "https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan"
        );
        assert_eq!(value["personalization"]["state"], "available");
        assert_eq!(value["personalization"]["writable"], false);
        assert!(value["personalization"]["features"]
            .as_array()
            .is_some_and(|items| items.iter().any(|item| item == "下载页模板")));
        assert!(value["accountFeatures"]
            .as_array()
            .is_some_and(|items| items.iter().any(|item| item == "云存储统计")));
        assert_eq!(value["acceptsPaymentData"], false);
        let serialized = value.to_string();
        assert!(!serialized.contains("private-session-cookie"));
        assert!(!serialized.contains("password"));
        assert!(!serialized.contains("card"));
    }

    #[test]
    fn test_login_preflights_and_merges_cookies_for_bootstrap() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let base = format!("http://{address}");
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0_u8; 4096];
            let read = stream.read(&mut buffer).unwrap();
            let first = String::from_utf8_lossy(&buffer[..read]).to_string();
            if !first.starts_with("GET /mlogin.php ") {
                let body = r#"{"zt":0,"info":"missing preflight"}"#;
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
                return;
            }
            let body = "login page";
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nSet-Cookie: acw_tc=preflight; Path=/\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();

            let (mut stream, _) = listener.accept().unwrap();
            let read = stream.read(&mut buffer).unwrap();
            let second = String::from_utf8_lossy(&buffer[..read]).to_string();
            assert!(second.starts_with("POST /mlogin.php?istoken=3 "));
            assert!(second.contains("acw_tc=preflight"));
            let body = r#"{"zt":1,"info":"ok"}"#;
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nSet-Cookie: ylogin=session; Path=/\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();

            let (mut stream, _) = listener.accept().unwrap();
            let read = stream.read(&mut buffer).unwrap();
            let third = String::from_utf8_lossy(&buffer[..read]).to_string();
            assert!(third.starts_with("GET /mydisk.php?"));
            assert!(third.contains("acw_tc=preflight"));
            assert!(third.contains("ylogin=session"));
            let body = "<script>var url='?uid=123&x=1'; data:{'vei':'456'}</script>";
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });

        let mut client = SessionClient::for_test(base).unwrap();
        let value = client.login("account", "password").unwrap();
        assert_eq!(value["authenticated"], true);
        assert!(client.cookie.contains("acw_tc=preflight"));
        assert!(client.cookie.contains("ylogin=session"));
        server.join().unwrap();
    }

    #[test]
    fn test_file_rename_sends_stem_because_woozooo_keeps_extension() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let base = format!("http://{address}");
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 4096];
            let read = stream.read(&mut request).unwrap();
            let request = String::from_utf8_lossy(&request[..read]);
            let body = request.split("\r\n\r\n").nth(1).unwrap_or_default();
            assert!(body.contains("task=46"));
            assert!(body.contains("file_id=7"));
            assert!(body.contains("file_name=renamed"));
            assert!(!body.contains("file_name=renamed.zip"));
            let response = r#"{"zt":1,"info":"修改成功","text":null}"#;
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response}",
                response.len()
            )
            .unwrap();
        });
        let mut client = SessionClient::for_test(base).unwrap();
        client.cookie = "session=ok".to_owned();
        client.uid = "123".to_owned();
        client.vei = "456".to_owned();

        let value = client.rename("7", false, "renamed.zip").unwrap();

        assert_eq!(value["name"], "renamed.zip");
        server.join().unwrap();
    }

    #[test]
    fn test_http_mock_resolves_share_redirect() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let base = format!("http://{address}");
        let server_base = base.clone();
        let server = std::thread::spawn(move || {
            let responses = [
                (
                    200,
                    "<iframe src=\"/fn?token=frame\"></iframe>".to_owned(),
                    None,
                ),
                (
                    200,
                    "var wp_sign='token'; var ajaxdata='guard'; var kdns=1; $.ajax({url:'/fn/ajaxm.php?file=123',data:{'action':'downprocess','websignkey':ajaxdata,'signs':ajaxdata,'sign':wp_sign,'websign':'','kd':kdns,'ves':1}});".to_owned(),
                    None,
                ),
                (
                    200,
                    format!(r#"{{"zt":1,"dom":"{server_base}","url":"abc"}}"#),
                    None,
                ),
                (302, String::new(), Some("/direct.bin".to_owned())),
            ];
            for (index, (status, body, location)) in responses.into_iter().enumerate() {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0_u8; 4096];
                let read = stream.read(&mut request).unwrap();
                let request = String::from_utf8_lossy(&request[..read]).to_ascii_lowercase();
                if index == 2 {
                    assert!(request.starts_with("post /fn/ajaxm.php?file=123 "));
                    assert!(request.contains(&format!("referer: {server_base}/fn?token=frame")));
                    assert!(request.contains(&format!("origin: {server_base}")));
                    assert!(request.contains("x-requested-with: xmlhttprequest"));
                    assert!(request.contains("action=downprocess"));
                    assert!(request.contains("websignkey=guard"));
                    assert!(request.contains("signs=guard"));
                    assert!(request.contains("sign=token"));
                }
                if index == 3 {
                    assert!(request.contains(&format!("referer: {server_base}/file")));
                }
                let location = location
                    .map(|value| format!("Location: {value}\r\n"))
                    .unwrap_or_default();
                write!(
                    stream,
                    "HTTP/1.1 {status} Mock\r\n{location}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
        });
        let client = SessionClient::for_test(base.clone()).unwrap();
        assert_eq!(
            client
                .resolve_direct_url(&format!("{base}/share"), "")
                .unwrap(),
            format!("{base}/direct.bin")
        );
        server.join().unwrap();
    }

    #[test]
    fn test_http_mock_resolves_password_page_without_using_ad_iframe() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let base = format!("http://{address}");
        let server_base = base.clone();
        let server = std::thread::spawn(move || {
            let responses = [
                (
                    200,
                    "<iframe src='/ad/banner'></iframe><div id='passwddiv'></div><script>var sg='token'; function down_p(){ $.ajax({url:'/ajaxm.php',data:{'action':'downprocess','sign':sg,'p':'','kd':1}}); }</script>".to_owned(),
                    None,
                ),
                (
                    200,
                    format!(r#"{{"zt":1,"dom":"{server_base}","url":"abc"}}"#),
                    None,
                ),
                (302, String::new(), Some(format!("{server_base}/direct.bin"))),
            ];
            for (index, (status, body, location)) in responses.into_iter().enumerate() {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0_u8; 4096];
                let read = stream.read(&mut request).unwrap();
                let request = String::from_utf8_lossy(&request[..read]).to_ascii_lowercase();
                if index == 1 {
                    assert!(request.starts_with("post /ajaxm.php "));
                    assert!(request.contains("x-requested-with: xmlhttprequest"));
                    assert!(request.contains("action=downprocess"));
                    assert!(request.contains("sign=token"));
                    assert!(request.contains("p=a2"));
                }
                let location = location
                    .map(|value| format!("Location: {value}\r\n"))
                    .unwrap_or_default();
                write!(
                    stream,
                    "HTTP/1.1 {status} Mock\r\n{location}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
        });
        let client = SessionClient::for_test(base.clone()).unwrap();
        assert_eq!(
            client
                .resolve_direct_url(&format!("{base}/share"), "a2")
                .unwrap(),
            format!("{base}/direct.bin")
        );
        server.join().unwrap();
    }

    #[test]
    fn test_http_mock_accepts_absolute_secondary_verification_url() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let base = format!("http://{address}");
        let server_base = base.clone();
        let server = std::thread::spawn(move || {
            let responses = [
                (
                    200,
                    "var sg='token'; $.ajax({url:'/ajaxm.php?file=123',data:{'action':'downprocess','sign':sg}});".to_owned(),
                ),
                (
                    200,
                    format!(r#"{{"zt":1,"dom":"{server_base}","url":"abc"}}"#),
                ),
                (200, "data:{'file':'abc','sign':'verify'}".to_owned()),
                (
                    200,
                    format!(r#"{{"zt":1,"url":"{server_base}/direct.bin"}}"#),
                ),
            ];
            for (index, (status, body)) in responses.into_iter().enumerate() {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0_u8; 4096];
                let read = stream.read(&mut request).unwrap();
                if index == 3 {
                    let request = String::from_utf8_lossy(&request[..read]).to_ascii_lowercase();
                    assert!(request.starts_with("post /file/ajax.php "));
                    assert!(request.contains("el=2"));
                }
                write!(
                    stream,
                    "HTTP/1.1 {status} Mock\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
        });
        let client = SessionClient::for_test(base.clone()).unwrap();
        assert_eq!(
            client
                .resolve_direct_url(&format!("{base}/share"), "")
                .unwrap(),
            format!("{base}/direct.bin")
        );
        server.join().unwrap();
    }

    #[test]
    fn test_share_info_keeps_metadata_when_direct_url_resolution_fails() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let base = format!("http://{address}");
        let share_base = base.clone();
        let server = std::thread::spawn(move || {
            for index in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0_u8; 4096];
                let _ = stream.read(&mut request).unwrap();
                let (status, body) = match index {
                    0 => (
                        200,
                        format!(
                            r#"{{"zt":1,"info":{{"f_id":"share","is_newd":"{share_base}","onof":"0"}}}}"#
                        ),
                    ),
                    1 => (
                        200,
                        r#"{"zt":1,"text":"sample.zip","info":"description"}"#.to_owned(),
                    ),
                    _ => (405, "method not allowed".to_owned()),
                };
                write!(
                    stream,
                    "HTTP/1.1 {status} Mock\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
        });
        let mut client = SessionClient::for_test(base).unwrap();
        client.cookie = "session=ok".to_owned();
        client.uid = "123".to_owned();
        client.vei = "456".to_owned();

        let value = client.share_info("7", false).unwrap();

        assert_eq!(value["name"], "sample.zip");
        assert_eq!(value["description"], "description");
        assert!(value["directUrl"].is_null());
        server.join().unwrap();
    }
}
