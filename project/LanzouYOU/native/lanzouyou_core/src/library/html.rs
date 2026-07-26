use std::collections::BTreeMap;

use regex::Regex;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum PageTemplate {
    #[default]
    Unknown,
    Minimal,
    Classic,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct ParsedPage {
    pub title: String,
    pub publisher: String,
    pub avatar_url: String,
    pub description: String,
    pub save_url: String,
    pub listing_endpoint: String,
    pub folder_endpoint: String,
    pub search_endpoint: String,
    pub search_sign: String,
    pub fid: String,
    pub form: BTreeMap<String, String>,
    pub static_folders: Vec<StaticFolder>,
    pub template: PageTemplate,
    pub cancelled: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct ParsedSingleFile {
    pub title: String,
    pub icon_url: String,
    pub size: String,
    pub time: String,
    pub description: String,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct StaticFolder {
    pub title: String,
    pub href: String,
    pub description: String,
}

pub(crate) fn parse_page(html: &str) -> ParsedPage {
    let template = page_template(html);
    let listing_endpoint = capture(
        html,
        r#"url\s*:\s*['\"]([^'\"]*filemoreajax\.php\?file=\d+[^'\"]*)['\"]"#,
    );
    let mut form = form_values(html);
    let fid = capture(&listing_endpoint, r"[?&]file=([^&#]+)");
    form.insert("fid".to_owned(), fid.clone());
    form.entry("lx".to_owned())
        .or_insert_with(|| "2".to_owned());
    form.entry("rep".to_owned())
        .or_insert_with(|| "0".to_owned());
    form.entry("up".to_owned())
        .or_insert_with(|| "1".to_owned());
    form.entry("vip".to_owned())
        .or_insert_with(|| "0".to_owned());

    let html_title = strip(&capture(html, r"(?is)<title[^>]*>(.*?)</title>"));
    let title = first_non_empty(&[strip(&div_inner_by_class(html, "user-title")), html_title]);
    let publisher = strip(&div_inner_by_class(html, "user-name"))
        .split("的分享文件")
        .next()
        .unwrap_or_default()
        .trim()
        .to_owned();
    let avatar_url = capture(
        html,
        r#"(?is)class=['\"](?:user-ico-img|passwddiv-userico-img)['\"][^>]*style=['\"][^'\"]*background\s*:\s*url\(([^)]+)\)"#,
    )
    .replace("\\/", "/")
    .trim_matches(['\'', '"'])
    .to_owned();
    let description = strip(&div_inner_by_class(html, "user-radio"));
    let save_url = capture(
        html,
        r#"(?is)<div[^>]+id=['\"]save['\"][^>]*>\s*<a[^>]+href=['\"]([^'\"]+)"#,
    );
    let folder_endpoint = capture(
        html,
        r#"url\s*:\s*['\"]([^'\"]*foldermoreajax\.php\?file=\d+[^'\"]*)['\"]"#,
    );
    let search_endpoint = capture(
        html,
        r#"url\s*:\s*['\"]([^'\"]*/search/s\.php\?file=\d+[^'\"]*)['\"]"#,
    );
    let search_sign = capture(html, r#"['\"]sign['\"]\s*:\s*['\"]([^'\"]+)['\"]"#);

    ParsedPage {
        title,
        publisher,
        avatar_url,
        description,
        save_url,
        listing_endpoint,
        folder_endpoint,
        search_endpoint,
        search_sign,
        fid,
        form,
        static_folders: parse_static_folders(html),
        template,
        cancelled: is_cancelled_share_with_template(html, template),
    }
}

pub(crate) fn page_template(html: &str) -> PageTemplate {
    let value = html.to_ascii_lowercase();
    let minimal = value.contains("/assets/share/folder2.css")
        && (value.contains("/assets/share/folder3.css")
            || value.contains("/assets/share/folder4.css"))
        && value.contains("user-top")
        && value.contains("fileview");
    if minimal {
        return PageTemplate::Minimal;
    }
    let has_info = value.contains("id=\"info\"") || value.contains("id='info'");
    let classic = value.contains("/assets/img/t0.css")
        && (value.contains("/assets/share/folder6.css")
            || value.contains("/assets/share/folder8.css")
            || value.contains("/assets/share/folder9.css"))
        && has_info;
    if classic {
        PageTemplate::Classic
    } else {
        PageTemplate::Unknown
    }
}

#[cfg(test)]
pub(crate) fn is_cancelled_share(html: &str) -> bool {
    is_cancelled_share_with_template(html, page_template(html))
}

fn is_cancelled_share_with_template(html: &str, template: PageTemplate) -> bool {
    if html.contains("filemoreajax.php") || template != PageTemplate::Unknown {
        return false;
    }
    let compact = strip(html)
        .split_whitespace()
        .collect::<String>()
        .replace(['，', ','], "");
    [
        "分享已取消",
        "文件取消分享",
        "文件已取消分享",
        "已被取消分享",
        "文件不存在或已删除",
    ]
    .iter()
    .any(|marker| compact.contains(marker))
}

pub(crate) fn parse_file_description(html: &str) -> String {
    let mut value = first_non_empty(&[
        strip(&div_inner_by_class(html, "appdes")),
        strip(&div_inner_by_class(html, "file-des")),
        strip(&div_inner_by_class(html, "n_file_info")),
        strip(&capture(
            html,
            r#"(?is)<meta[^>]+name=['\"]description['\"][^>]+content=['\"]([^'\"]*)"#,
        )),
    ]);
    if let Ok(prefix) = Regex::new(r"^(?:文件)?(?:描述|简介)\s*[：:]\s*") {
        value = prefix.replace(&value, "").trim().to_owned();
    }
    if value == "蓝奏云" || value.starts_with("文件大小：") || value.starts_with("大小：")
    {
        String::new()
    } else {
        value
    }
}

/// Detects and parses a public single-file share by its rendered contract.
///
/// `/s/...` is also used by directory shares, so path-based classification is
/// incorrect. Keep this aligned with the content markers used by LanzouPlus:
/// download transfer links, the mobile iframe, or a current file layout.
pub(crate) fn parse_single_file_page(html: &str) -> Option<ParsedSingleFile> {
    if html.trim().is_empty()
        || Regex::new(r"(?i)filemoreajax\.php")
            .ok()
            .is_some_and(|pattern| pattern.is_match(html))
    {
        return None;
    }

    let html_title = strip(&capture(html, r"(?is)<title[^>]*>(.*?)</title>"));
    let meta_description = strip(&capture(
        html,
        r#"(?is)<meta[^>]+name=['\"]description['\"][^>]+content=['\"]([^'\"]*)"#,
    ));
    let explicit_marker = [
        r#"(?is)id=['\"]downurl['\"][^>]*href=['\"][^'\"]+"#,
        r#"(?is)<iframe[^>]+src=['\"][^'\"]*/fn\?[^'\"]+"#,
        r#"(?is)class=['\"][^'\"]*\bappfile\b[^'\"]*['\"]"#,
        r#"(?is)id=['\"]filenajax['\"]"#,
    ]
    .iter()
    .any(|pattern| {
        Regex::new(pattern)
            .ok()
            .is_some_and(|pattern| pattern.is_match(html))
    });
    let title_and_size_marker = Regex::new(r"(?is)^.+?\s*-\s*(?:蓝奏云|lanzou)\s*$")
        .ok()
        .is_some_and(|pattern| pattern.is_match(&html_title))
        && (meta_description.contains("文件大小") || meta_description.contains("大小："));
    if !explicit_marker && !title_and_size_marker {
        return None;
    }

    let raw_title = first_non_empty(&[
        strip(&div_inner_by_class(html, "appname")),
        strip(&div_inner_by_id(html, "filenajax")),
        html_title,
    ]);
    let title = Regex::new(r"(?i)[\s_-]*(?:蓝奏云|lanzou).*$")
        .map(|pattern| pattern.replace(&raw_title, "").trim().to_owned())
        .unwrap_or(raw_title);
    let icon_url = first_non_empty(&[
        capture(
            html,
            r#"(?is)<meta[^>]+(?:property|name)=['\"](?:og:image|twitter:image)['\"][^>]+content=['\"]([^'\"]+)"#,
        ),
        capture(
            html,
            r#"(?is)<img[^>]+class=['\"][^'\"]*(?:appico|file-ico|n_file_ico)[^'\"]*['\"][^>]+src=['\"]([^'\"]+)"#,
        ),
        capture(
            html,
            r#"(?is)<img[^>]+src=['\"]([^'\"]+)['\"][^>]+class=['\"][^'\"]*(?:appico|file-ico|n_file_ico)"#,
        ),
        capture(
            html,
            r#"(?is)class=['\"][^'\"]*appico[^'\"]*['\"][^>]+style=['\"][^'\"]*background\s*:\s*url\(([^)]+)\)"#,
        ),
    ])
    .replace("\\/", "/")
    .trim_matches(['\'', '"'])
    .to_owned();
    let size = strip(&first_non_empty(&[
        capture(
            html,
            r#"(?is)(?:文件)?大小\s*[：:]?\s*</?[^>]*>\s*([^<\r\n]+)"#,
        ),
        capture(
            html,
            r#"(?is)class=['\"][^'\"]*(?:filesize|n_filesize)[^'\"]*['\"][^>]*>(.*?)</"#,
        ),
        capture(
            html,
            r#"(?is)<meta[^>]+name=['\"]description['\"][^>]+content=['\"][^'\"]*(?:文件)?大小\s*[:：]\s*([^'\"]+)"#,
        ),
    ]));
    let time = capture(html, r"((?:19|20)\d{2}[-/.]\d{1,2}[-/.]\d{1,2})").replace(['/', '.'], "-");

    Some(ParsedSingleFile {
        title: if title.is_empty() {
            "未命名软件".to_owned()
        } else {
            title
        },
        icon_url,
        size,
        time,
        description: parse_file_description(html),
    })
}

pub(crate) fn capture(input: &str, pattern: &str) -> String {
    Regex::new(pattern)
        .ok()
        .and_then(|regex| regex.captures(input))
        .and_then(|captures| {
            captures
                .get(1)
                .map(|value| value.as_str().trim().to_owned())
        })
        .map(|value| unescape(&value))
        .unwrap_or_default()
}

pub(crate) fn strip(value: &str) -> String {
    let breaks = Regex::new(r"(?is)<br\s*/?>")
        .map(|regex| regex.replace_all(value, "\n").into_owned())
        .unwrap_or_else(|_| value.to_owned());
    let tags = Regex::new(r"(?is)<[^>]+>")
        .map(|regex| regex.replace_all(&breaks, "").into_owned())
        .unwrap_or(breaks);
    unescape(tags.trim())
}

pub(crate) fn div_inner_by_class(html: &str, class_name: &str) -> String {
    let Ok(opener) = Regex::new(&format!(
        r#"(?is)<div[^>]*class=['\"][^'\"]*\b{}\b[^'\"]*['\"][^>]*>"#,
        regex::escape(class_name)
    )) else {
        return String::new();
    };
    let Some(opening) = opener.find(html) else {
        return String::new();
    };
    balanced_div_inner(html, opening.end())
}

fn div_inner_by_id(html: &str, id: &str) -> String {
    let Ok(opener) = Regex::new(&format!(
        r#"(?is)<div[^>]*\bid=['\"]{}['\"][^>]*>"#,
        regex::escape(id)
    )) else {
        return String::new();
    };
    let Some(opening) = opener.find(html) else {
        return String::new();
    };
    balanced_div_inner(html, opening.end())
}

fn parse_static_folders(html: &str) -> Vec<StaticFolder> {
    let Some(block_start) = Regex::new(r#"(?is)<div[^>]*\bid=['\"]folder['\"][^>]*>"#)
        .ok()
        .and_then(|regex| regex.find(html))
    else {
        return Vec::new();
    };
    let block = balanced_div_inner(html, block_start.end());
    let Ok(openers) =
        Regex::new(r#"(?is)<div[^>]*class=['\"][^'\"]*\bmbxfolder\b[^'\"]*['\"][^>]*>"#)
    else {
        return Vec::new();
    };
    let mut folders = Vec::new();
    for opening in openers.find_iter(&block) {
        let inner = balanced_div_inner(&block, opening.end());
        let href = capture(&inner, r#"(?is)<a[^>]+href=['\"]([^'\"]+)"#);
        let filename = div_inner_by_class(&inner, "filename");
        let description = strip(&div_inner_by_class(&filename, "filesize"));
        let mut title = capture(&filename, r"(?is)^\s*([^<]+)");
        if title.is_empty() {
            title = strip(&filename).replace(&description, "").trim().to_owned();
        }
        if !href.is_empty() && !title.is_empty() {
            folders.push(StaticFolder {
                title,
                href,
                description,
            });
        }
    }
    folders
}

fn balanced_div_inner(html: &str, content_start: usize) -> String {
    let Ok(tags) = Regex::new(r"(?is)</?div\b[^>]*>") else {
        return String::new();
    };
    let mut depth = 1usize;
    for tag in tags.find_iter(&html[content_start..]) {
        if tag.as_str().trim_start().starts_with("</") {
            depth = depth.saturating_sub(1);
            if depth == 0 {
                return html[content_start..content_start + tag.start()].to_owned();
            }
        } else {
            depth += 1;
        }
    }
    String::new()
}

fn form_values(html: &str) -> BTreeMap<String, String> {
    let mut variables = BTreeMap::new();
    if let Ok(regex) =
        Regex::new(r#"(?:var\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*['\"]([^'\"]*)['\"]"#)
    {
        for captures in regex.captures_iter(html) {
            if let (Some(key), Some(value)) = (captures.get(1), captures.get(2)) {
                variables.insert(key.as_str().to_owned(), unescape(value.as_str()));
            }
        }
    }
    let mut output = BTreeMap::new();
    for key in [
        "lx",
        "uid",
        "puid",
        "rep",
        "t",
        "k",
        "up",
        "webfoldersign",
        "ls",
        "vip",
    ] {
        let pattern = format!(
            r#"['\"]{}['\"]\s*:\s*(?:['\"]([^'\"]*)['\"]|([A-Za-z_][A-Za-z0-9_]*))"#,
            regex::escape(key)
        );
        let Some(captures) = Regex::new(&pattern)
            .ok()
            .and_then(|regex| regex.captures(html))
        else {
            continue;
        };
        let value = captures
            .get(1)
            .map(|value| unescape(value.as_str()))
            .or_else(|| {
                captures
                    .get(2)
                    .and_then(|name| variables.get(name.as_str()).cloned())
            })
            .unwrap_or_default();
        output.insert(key.to_owned(), value);
    }
    output
}

fn first_non_empty(values: &[String]) -> String {
    values
        .iter()
        .find(|value| !value.trim().is_empty())
        .map(|value| value.trim().to_owned())
        .unwrap_or_default()
}

fn unescape(value: &str) -> String {
    value
        .replace("&amp;", "&")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_page_reads_metadata_endpoints_and_form() {
        let html = r#"
        <title>回退标题</title><div class="user-title">软件库合集</div>
        <div class="user-name">发布者<span>的分享文件</span></div>
        <div class="user-radio">第一行<br>第二行</div>
        <div id="save"><a href="https://www.ilanzou.com/save">保存</a></div>
        <script>var token='abc'; var pwd; url:'/filemoreajax.php?file=9';
        const folder={url:'/foldermoreajax.php?file=9'};
        const search={url:'/search/s.php?file=9','sign':'sig','t':token,'uid':'7'};</script>"#;
        let page = parse_page(html);
        assert_eq!(page.title, "软件库合集");
        assert_eq!(page.publisher, "发布者");
        assert_eq!(page.description, "第一行\n第二行");
        assert_eq!(page.fid, "9");
        assert_eq!(page.form.get("t").map(String::as_str), Some("abc"));
        assert_eq!(page.search_sign, "sig");
    }

    #[test]
    fn test_parse_page_reads_nested_static_folders() {
        let html = r#"<div id="folder"><div class="mbx mbxfolder"><a href="/b2"><div class="filename">工具合集<div class="filesize">精选</div></div></a></div></div>"#;
        let folders = parse_page(html).static_folders;
        assert_eq!(folders.len(), 1);
        assert_eq!(folders[0].title, "工具合集");
        assert_eq!(folders[0].description, "精选");
    }

    #[test]
    fn test_file_description_discards_size_only_metadata() {
        assert_eq!(
            parse_file_description(r#"<meta name="description" content="文件大小：1 M">"#),
            ""
        );
        assert_eq!(
            parse_file_description(
                r#"<div class="n_file_info">官网链接：https://example.com</div>"#
            ),
            "官网链接：https://example.com"
        );
    }

    #[test]
    fn test_page_template_detects_current_minimal_classic_and_unknown_layouts() {
        let minimal = r#"
            <link href="/assets/share/folder2.css">
            <link href="/assets/share/folder4.css">
            <div class="user-top"><div class="fileview"></div></div>
        "#;
        let classic = r#"
            <link href="/assets/img/t0.css">
            <link href="/assets/share/folder8.css">
            <div id='info'></div>
        "#;

        assert_eq!(page_template(minimal), PageTemplate::Minimal);
        assert_eq!(page_template(classic), PageTemplate::Classic);
        assert_eq!(
            page_template("<html>maintenance</html>"),
            PageTemplate::Unknown
        );
    }

    #[test]
    fn test_cancelled_share_is_terminal_only_for_unknown_non_directory_page() {
        assert!(is_cancelled_share(
            "<main> 文件 已取消分享，无法访问 </main>"
        ));
        assert!(is_cancelled_share("<p>文件不存在或已删除</p>"));
        assert!(!is_cancelled_share(
            "<script>url:'/filemoreajax.php?file=9'</script><p>旧提示：分享已取消</p>"
        ));
        assert!(!is_cancelled_share(
            r#"<link href="/assets/share/folder2.css"><link href="/assets/share/folder3.css"><div class="user-top fileview">分享已取消</div>"#
        ));
    }

    #[test]
    fn test_single_file_page_uses_content_markers_and_reads_real_metadata() {
        let html = r#"
            <title>旧标题.apk - 蓝奏云</title>
            <meta property="og:image" content="https://image.dmpdmp.com/image/ico/tool.png">
            <div class="appfile">
              <div id="filenajax">工具新版.apk</div>
              <span class="filesize">12.5 M</span>
              <div class="appdes">第一行<br>第二行</div>
              <a id="downurl" href="/tp/demo">下载</a>
            </div>
            <time>2026-07-15</time>
        "#;

        let file = parse_single_file_page(html).expect("current single-file page must parse");

        assert_eq!(file.title, "工具新版.apk");
        assert_eq!(file.icon_url, "https://image.dmpdmp.com/image/ico/tool.png");
        assert_eq!(file.size, "12.5 M");
        assert_eq!(file.time, "2026-07-15");
        assert_eq!(file.description, "第一行\n第二行");
    }

    #[test]
    fn test_single_file_detection_is_content_based_not_s_path_based() {
        assert!(parse_single_file_page(
            r#"<title>应用.apk - Lanzou</title><meta name="description" content="文件大小：8 M">"#
        )
        .is_some());
        assert!(parse_single_file_page(
            r#"<iframe src="/fn?abc"></iframe><div class="appname">应用.apk</div>"#
        )
        .is_some());
        assert!(parse_single_file_page(r#"<div id="filenajax">应用.apk</div>"#).is_some());
        assert!(parse_single_file_page(
            r#"<title>目录 - 蓝奏云</title><script>url:'/filemoreajax.php?file=9'</script><a id="downurl" href="/tp/demo">下载</a>"#
        )
        .is_none());
        assert!(parse_single_file_page("<html>普通页面</html>").is_none());
    }
}
