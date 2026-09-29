use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::Mutex,
};

use once_cell::sync::Lazy;
use reqwest::Url;

use crate::error::{CoreError, CoreResult};

use super::session::{
    ANDROID_USER_AGENT, DESKTOP_EDGE_USER_AGENT, DESKTOP_USER_AGENT, MOBILE_FIREFOX_USER_AGENT,
    MOBILE_HUAWEI_USER_AGENT,
};

const MAX_PROFILE_ENTRIES: usize = 512;
const BASE_ORIGINS: &[&str] = &[
    "https://www.lanzouw.com",
    "https://wwop.lanzoul.com",
    "https://www.lanzoul.com",
    "https://www.lanzoux.com",
    "https://wwc.lanzouw.com",
    "https://wwc.lanzoux.com",
    "https://www.lanzoup.com",
    "https://www.lanzouo.com",
    "https://www.lanzouz.com",
    "https://www.lanzouq.com",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum NetworkScope {
    FileList,
    DirectorySearch,
    ApiSearch,
    Direct,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum UserAgentProfile {
    MobileChrome,
    DesktopChrome,
    DesktopEdge,
    MobileHuawei,
    MobileFirefox,
}

impl UserAgentProfile {
    pub(crate) const ALL: [Self; 5] = [
        Self::MobileChrome,
        Self::DesktopChrome,
        Self::DesktopEdge,
        Self::MobileHuawei,
        Self::MobileFirefox,
    ];

    pub(crate) fn user_agent(self) -> &'static str {
        match self {
            Self::MobileChrome => ANDROID_USER_AGENT,
            Self::DesktopChrome => DESKTOP_USER_AGENT,
            Self::DesktopEdge => DESKTOP_EDGE_USER_AGENT,
            Self::MobileHuawei => MOBILE_HUAWEI_USER_AGENT,
            Self::MobileFirefox => MOBILE_FIREFOX_USER_AGENT,
        }
    }

    pub(crate) fn is_desktop(self) -> bool {
        matches!(self, Self::DesktopChrome | Self::DesktopEdge)
    }

    pub(crate) fn key(self) -> &'static str {
        match self {
            Self::MobileChrome => "mobile-chrome",
            Self::DesktopChrome => "desktop-chrome",
            Self::DesktopEdge => "desktop-edge",
            Self::MobileHuawei => "mobile-huawei",
            Self::MobileFirefox => "mobile-firefox",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RouteCandidate {
    pub(crate) url: String,
    pub(crate) origin: String,
    pub(crate) agent: UserAgentProfile,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RoutePreference {
    origin: String,
    agent: UserAgentProfile,
}

#[derive(Default)]
struct ProfileStore {
    preferred: HashMap<(String, NetworkScope), RoutePreference>,
    recency: VecDeque<(String, NetworkScope)>,
}

impl ProfileStore {
    fn get(&mut self, key: &(String, NetworkScope)) -> Option<RoutePreference> {
        let value = self.preferred.get(key).cloned();
        if value.is_some() {
            self.touch(key);
        }
        value
    }

    fn put(&mut self, key: (String, NetworkScope), value: RoutePreference) {
        if self.preferred.contains_key(&key) {
            self.preferred.insert(key.clone(), value);
            self.touch(&key);
            return;
        }
        while self.preferred.len() >= MAX_PROFILE_ENTRIES {
            let Some(oldest) = self.recency.pop_front() else {
                break;
            };
            if self.preferred.remove(&oldest).is_some() {
                break;
            }
        }
        self.preferred.insert(key.clone(), value);
        self.recency.push_back(key);
    }

    fn touch(&mut self, key: &(String, NetworkScope)) {
        if let Some(index) = self.recency.iter().position(|candidate| candidate == key) {
            self.recency.remove(index);
        }
        self.recency.push_back(key.clone());
    }
}

static PROFILES: Lazy<Mutex<ProfileStore>> = Lazy::new(|| Mutex::new(ProfileStore::default()));

fn source_key(value: &str) -> CoreResult<String> {
    let mut parsed = Url::parse(value).map_err(|_| CoreError::invalid("分享链接格式无效"))?;
    parsed.set_fragment(None);
    Ok(parsed.to_string())
}

fn route_url(value: &str) -> CoreResult<String> {
    let mut parsed = Url::parse(value).map_err(|_| CoreError::invalid("分享链接格式无效"))?;
    if parsed
        .fragment()
        .is_none_or(|fragment| !fragment.starts_with("lanzou-folder="))
    {
        parsed.set_fragment(None);
    }
    Ok(parsed.to_string())
}

fn route_origin(value: &str) -> CoreResult<String> {
    let parsed = Url::parse(value).map_err(|_| CoreError::invalid("分享链接格式无效"))?;
    let host = parsed
        .host_str()
        .ok_or_else(|| CoreError::invalid("分享链接缺少主机"))?;
    let mut origin = format!("{}://{}", parsed.scheme(), host);
    if let Some(port) = parsed.port() {
        origin.push(':');
        origin.push_str(&port.to_string());
    }
    Ok(origin)
}

fn route_on_origin(value: &str, origin: &str) -> CoreResult<String> {
    let source = Url::parse(value).map_err(|_| CoreError::invalid("分享链接格式无效"))?;
    let base = Url::parse(origin).map_err(|_| CoreError::invalid("基础链接格式无效"))?;
    let host = base
        .host_str()
        .ok_or_else(|| CoreError::invalid("基础链接缺少主机"))?;
    let mut routed = source;
    routed
        .set_scheme(base.scheme())
        .map_err(|_| CoreError::invalid("基础链接协议无效"))?;
    routed
        .set_host(Some(host))
        .map_err(|_| CoreError::invalid("基础链接主机无效"))?;
    routed
        .set_port(base.port())
        .map_err(|_| CoreError::invalid("基础链接端口无效"))?;
    Ok(routed.to_string())
}

fn preference(value: &str, scope: NetworkScope) -> Option<RoutePreference> {
    let key = source_key(value).ok().map(|value| (value, scope))?;
    PROFILES
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(&key)
}

pub(crate) fn preferred_agents(value: &str, scope: NetworkScope) -> Vec<UserAgentProfile> {
    let preferred = preference(value, scope).map(|value| value.agent);
    let mut agents = Vec::with_capacity(UserAgentProfile::ALL.len());
    if let Some(preferred) = preferred {
        agents.push(preferred);
    }
    for candidate in UserAgentProfile::ALL {
        if !agents.contains(&candidate) {
            agents.push(candidate);
        }
    }
    agents
}

fn preferred_origins(value: &str, scope: NetworkScope) -> CoreResult<Vec<String>> {
    let routed = route_url(value)?;
    let current = route_origin(&routed)?;
    let preferred = preference(value, scope).map(|value| value.origin);
    let mut origins = Vec::with_capacity(BASE_ORIGINS.len().saturating_add(2));
    let mut seen = HashSet::new();
    if let Some(origin) = preferred {
        if seen.insert(origin.clone()) {
            origins.push(origin);
        }
    }
    if seen.insert(current.clone()) {
        origins.push(current);
    }
    for origin in BASE_ORIGINS {
        let origin = (*origin).to_owned();
        if seen.insert(origin.clone()) {
            origins.push(origin);
        }
    }
    Ok(origins)
}

pub(crate) fn candidates(value: &str, scope: NetworkScope) -> CoreResult<Vec<RouteCandidate>> {
    let canonical = source_key(value)?;
    let routed = route_url(value)?;
    let agents = preferred_agents(&canonical, scope);
    let origins = preferred_origins(&canonical, scope)?;
    let mut output = Vec::with_capacity(origins.len().saturating_mul(agents.len()));
    let mut seen = HashSet::new();

    for origin in &origins {
        for agent in agents.iter().copied() {
            if !seen.insert((origin.clone(), agent)) {
                continue;
            }
            output.push(RouteCandidate {
                url: route_on_origin(&routed, origin)?,
                origin: origin.clone(),
                agent,
            });
        }
    }
    Ok(output)
}

pub(crate) fn observe_success(value: &str, scope: NetworkScope, route: &RouteCandidate) {
    let Ok(key) = source_key(value) else {
        return;
    };
    PROFILES
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .put(
            (key, scope),
            RoutePreference {
                origin: route.origin.clone(),
                agent: route.agent,
            },
        );
}

fn terminal_route_error(error: &CoreError) -> bool {
    // Some Lanzou mirrors/UA combinations answer with a cancellation shell for a
    // live share. Do not let one candidate suppress the rest of the adaptive
    // origin/UA route list; if all candidates are cancelled, the last error still
    // surfaces as share_cancelled.
    matches!(error.code, "password_required" | "cancelled")
}

pub(crate) fn race_candidates<T, F>(
    routes: Vec<RouteCandidate>,
    attempt: F,
) -> CoreResult<(RouteCandidate, T)>
where
    F: Fn(RouteCandidate) -> CoreResult<T>,
{
    let mut last_error = None;
    let mut first_share_cancelled = None;
    for route in routes {
        match attempt(route.clone()) {
            Ok(value) => return Ok((route, value)),
            Err(error) if terminal_route_error(&error) => return Err(error),
            Err(error) if error.code == "share_cancelled" => {
                if first_share_cancelled.is_none() {
                    first_share_cancelled = Some(error);
                }
            }
            Err(error) => last_error = Some(error),
        }
    }
    match (last_error, first_share_cancelled) {
        (Some(error), Some(cancelled)) if error.code == "invalid_argument" => Err(cancelled),
        (Some(error), _) => Err(error),
        (None, Some(cancelled)) => Err(cancelled),
        (None, None) => Err(CoreError::remote("没有可用网络线路", true)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidates_cover_multiple_agents_and_origins_without_single_route_special_case() {
        let routes = candidates("https://www.lanzouw.com/test", NetworkScope::FileList).unwrap();
        let origins = routes
            .iter()
            .map(|route| route.origin.as_str())
            .collect::<HashSet<_>>();
        let agents = routes
            .iter()
            .map(|route| route.agent)
            .collect::<HashSet<_>>();
        assert!(origins.len() > 1);
        assert_eq!(agents.len(), UserAgentProfile::ALL.len());
        assert!(agents.iter().any(|profile| profile.is_desktop()));
        assert!(agents.iter().any(|profile| !profile.is_desktop()));
    }

    #[test]
    fn successful_route_and_profile_are_preferred_for_same_scope() {
        let value = "https://www.lanzouw.com/profile-test";
        let route = RouteCandidate {
            url: "https://www.lanzoux.com/profile-test".to_owned(),
            origin: "https://www.lanzoux.com".to_owned(),
            agent: UserAgentProfile::DesktopEdge,
        };
        observe_success(value, NetworkScope::ApiSearch, &route);
        let routes = candidates(value, NetworkScope::ApiSearch).unwrap();
        assert_eq!(
            routes.first().map(|route| route.origin.as_str()),
            Some(route.origin.as_str())
        );
        assert_eq!(
            preferred_agents(value, NetworkScope::ApiSearch).first(),
            Some(&route.agent)
        );
    }

    #[test]
    fn route_rewrite_preserves_share_path_and_virtual_folder_marker() {
        let routed = route_on_origin(
            "https://www.lanzouw.com/b1#lanzou-folder=42&title=tools",
            "https://www.lanzoux.com",
        )
        .unwrap();
        assert_eq!(
            routed,
            "https://www.lanzoux.com/b1#lanzou-folder=42&title=tools"
        );
    }

    #[test]
    fn single_share_cancelled_route_does_not_abort_fallback_candidates() {
        let routes = vec![
            RouteCandidate {
                url: "https://www.lanzouw.com/s/nanze".to_owned(),
                origin: "https://www.lanzouw.com".to_owned(),
                agent: UserAgentProfile::MobileChrome,
            },
            RouteCandidate {
                url: "https://wwc.lanzouw.com/s/nanze".to_owned(),
                origin: "https://wwc.lanzouw.com".to_owned(),
                agent: UserAgentProfile::DesktopChrome,
            },
        ];
        let (route, value) = race_candidates(routes, |route| {
            if route.origin == "https://www.lanzouw.com" {
                Err(CoreError::new("share_cancelled", "分享已取消", false))
            } else {
                Ok("parsed")
            }
        })
        .unwrap();
        assert_eq!(value, "parsed");
        assert_eq!(route.origin, "https://wwc.lanzouw.com");
    }
}
