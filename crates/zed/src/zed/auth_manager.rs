use gpui::{App, AppContext, Context, Entity, EventEmitter, Global};
use serde::{Deserialize, Serialize};

const WITCHCRAFT_WEB_URL: &str = "https://witchcraft.insanelabs.org";
const OAUTH_CALLBACK_SCHEME: &str = "witchcraft://";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AuthState {
    pub is_authenticated: bool,
    pub email: Option<String>,
    pub api_key: Option<String>,
    pub github_username: Option<String>,
}

impl Default for AuthState {
    fn default() -> Self {
        Self {
            is_authenticated: false,
            email: None,
            api_key: None,
            github_username: None,
        }
    }
}

pub enum AuthEvent {
    SignedIn,
    SignedOut,
    AuthError(String),
}

pub struct AuthManager {
    state: AuthState,
}

impl EventEmitter<AuthEvent> for AuthManager {}

// Wrapper to make Entity<AuthManager> implement Global
struct AuthManagerGlobal {
    manager: Entity<AuthManager>,
}

impl Global for AuthManagerGlobal {}

impl AuthManager {
    pub fn init(cx: &mut App) {
        let manager: Entity<Self> = cx.new(|_cx| Self {
            state: AuthState::default(),
        });

        // Load saved credentials on startup
        manager.update(cx, |this: &mut Self, cx| {
            this.load_credentials(cx);
        });

        cx.set_global(AuthManagerGlobal { manager });
    }

    pub fn handle_callback_global(url: String, cx: &mut App) {
        if let Some(auth_global) = cx.try_global::<AuthManagerGlobal>() {
            let manager = auth_global.manager.clone();
            manager.update(cx, |auth: &mut AuthManager, cx| {
                auth.handle_callback(&url, cx);
            });
        }
    }

    pub fn sign_in(&mut self, cx: &mut Context<Self>) {
        let oauth_url = format!("{}/auth/editor", WITCHCRAFT_WEB_URL);

        // Open the OAuth URL in the user's default browser
        if let Err(e) = open::that(&oauth_url) {
            log::error!("Failed to open browser for OAuth: {}", e);
            cx.emit(AuthEvent::AuthError(format!(
                "Could not open browser. Please visit: {}",
                oauth_url
            )));
        } else {
            log::info!("Browser opened for GitHub sign in...");
        }
    }

    pub fn handle_callback(&mut self, url: &str, cx: &mut Context<Self>) {
        if url.starts_with(&format!("{}auth/success", OAUTH_CALLBACK_SCHEME)) {
            self.handle_success(url, cx);
        } else if url.starts_with(&format!("{}auth/error", OAUTH_CALLBACK_SCHEME)) {
            self.handle_error(url, cx);
        } else {
            log::warn!("Unrecognized witchcraft:// URL format: {}", url);
        }
    }

    fn handle_success(&mut self, url: &str, cx: &mut Context<Self>) {
        if let Some(query_start) = url.find('?') {
            let query = &url[query_start + 1..];
            let params: std::collections::HashMap<String, String> =
                url::form_urlencoded::parse(query.as_bytes())
                    .into_owned()
                    .collect();

            let api_key = params.get("api_key").cloned();
            let email = params.get("email").cloned();
            let github_username = params.get("github_username").cloned();

            if let Some(key) = api_key {
                self.save_credentials(&key, email.as_deref(), github_username.as_deref());

                self.state.is_authenticated = true;
                self.state.api_key = Some(key);
                self.state.email = email;
                self.state.github_username = github_username;

                cx.emit(AuthEvent::SignedIn);
                cx.notify();
            }
        }
    }

    fn handle_error(&mut self, url: &str, cx: &mut Context<Self>) {
        if let Some(query_start) = url.find('?') {
            let query = &url[query_start + 1..];
            let params: std::collections::HashMap<String, String> =
                url::form_urlencoded::parse(query.as_bytes())
                    .into_owned()
                    .collect();

            let error = params
                .get("error")
                .map(|s| s.as_str())
                .unwrap_or("unknown");
            let description = params
                .get("description")
                .map(|s| s.as_str())
                .unwrap_or("");

            let error_msg = format!("Sign in failed: {} - {}", error, description);
            log::error!("{}", error_msg);
            cx.emit(AuthEvent::AuthError(error_msg));
        }
    }

    fn save_credentials(
        &self,
        api_key: &str,
        email: Option<&str>,
        github_username: Option<&str>,
    ) {
        let config_dir = dirs::config_dir()
            .unwrap_or_else(|| std::path::PathBuf::from("."))
            .join("witchcraft");

        if let Err(e) = std::fs::create_dir_all(&config_dir) {
            log::error!("Failed to create config directory: {}", e);
            return;
        }

        let config_file = config_dir.join("credentials.json");
        let credentials = serde_json::json!({
            "api_key": api_key,
            "email": email,
            "github_username": github_username,
        });

        if let Ok(json) = serde_json::to_string_pretty(&credentials) {
            if let Err(e) = std::fs::write(config_file, json) {
                log::error!("Failed to save credentials: {}", e);
            }
        }
    }

    fn load_credentials(&mut self, cx: &mut Context<Self>) {
        let config_dir = dirs::config_dir()
            .unwrap_or_else(|| std::path::PathBuf::from("."))
            .join("witchcraft");

        let config_file = config_dir.join("credentials.json");

        if let Ok(contents) = std::fs::read_to_string(config_file) {
            if let Ok(creds) = serde_json::from_str::<serde_json::Value>(&contents) {
                let api_key = creds["api_key"].as_str().map(String::from);
                let email = creds["email"].as_str().map(String::from);
                let github_username = creds["github_username"].as_str().map(String::from);

                if api_key.is_some() {
                    self.state.is_authenticated = true;
                    self.state.api_key = api_key;
                    self.state.email = email;
                    self.state.github_username = github_username;
                    cx.notify();
                }
            }
        }
    }

    pub fn sign_out(&mut self, cx: &mut Context<Self>) {
        let config_dir = dirs::config_dir()
            .unwrap_or_else(|| std::path::PathBuf::from("."))
            .join("witchcraft");

        let config_file = config_dir.join("credentials.json");
        std::fs::remove_file(config_file).ok();

        self.state = AuthState::default();
        cx.emit(AuthEvent::SignedOut);
        cx.notify();
    }

    pub fn get_api_key(&self) -> Option<String> {
        self.state.api_key.clone()
    }

    pub fn is_authenticated(&self) -> bool {
        self.state.is_authenticated
    }

    pub fn get_email(&self) -> Option<String> {
        self.state.email.clone()
    }

    pub fn get_github_username(&self) -> Option<String> {
        self.state.github_username.clone()
    }

    pub fn get_state(&self) -> &AuthState {
        &self.state
    }
}
