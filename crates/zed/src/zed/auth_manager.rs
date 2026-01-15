use gpui::{App, AppContext, Context, Entity, EventEmitter, Global};
use http_client::{AsyncBody, Request};
use reqwest_client::ReqwestClient;
use std::sync::Arc;
use futures::AsyncReadExt;
use serde::{Deserialize, Serialize};

const WITCHCRAFT_WEB_URL: &str = "https://witchcraft.insanelabs.org";
const OAUTH_CALLBACK_SCHEME: &str = "witchcraft://";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AuthState {
    pub is_authenticated: bool,
    pub email: Option<String>,
    pub api_key: Option<String>,
    pub github_username: Option<String>,
    pub full_name: Option<String>,
    pub avatar_url: Option<String>,
}

impl Default for AuthState {
    fn default() -> Self {
        Self {
            is_authenticated: false,
            email: None,
            api_key: None,
            github_username: None,
            full_name: None,
            avatar_url: None,
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

    /// Returns the global `AuthManager` entity if it has been initialized.
    pub fn global_entity(cx: &App) -> Option<Entity<AuthManager>> {
        cx.try_global::<AuthManagerGlobal>().map(|g| g.manager.clone())
    }

    pub fn handle_callback_global(url: String, cx: &mut App) {
        if let Some(auth_global) = cx.try_global::<AuthManagerGlobal>() {
            let manager = auth_global.manager.clone();
            manager.update(cx, |auth: &mut AuthManager, cx| {
                auth.handle_callback(&url, cx);
            });
        }
    }

    /// Global helper to start sign-in using an access code pasted into the editor.
    pub fn sign_in_with_access_code_global(access_code: String, cx: &mut App) {
        if let Some(auth_global) = cx.try_global::<AuthManagerGlobal>() {
            let manager = auth_global.manager.clone();
            let _ = manager.update(cx, |auth: &mut AuthManager, cx| {
                auth.sign_in_with_access_code(access_code, cx);
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

    /// Exchange an editor access code for an API key and user profile.
    ///
    /// This is used when the user pastes an access code from the browser into the editor.
    pub fn sign_in_with_access_code(&mut self, access_code: String, cx: &mut Context<Self>) {
        if access_code.trim().is_empty() {
            cx.emit(AuthEvent::AuthError(
                "Access code cannot be empty".to_string(),
            ));
            return;
        }

        let access_code = access_code.trim().to_string();
        let url = format!("{}/api/editor-access-login", WITCHCRAFT_WEB_URL);
        log::info!("Starting Witchcraft access-code sign in against {}", url);

        // Build HTTP client using the shared Reqwest-based implementation.
        let http: Arc<dyn http_client::HttpClient> = Arc::new(ReqwestClient::new());

        cx.spawn(async move |handle, cx| {
            // Build JSON body
            let body_bytes = match serde_json::to_vec(&serde_json::json!({ "accessCode": access_code })) {
                Ok(bytes) => bytes,
                Err(e) => {
                    log::error!("Failed to serialize access code body: {e}");
                    if let Some(manager) = handle.upgrade() {
                        manager
                            .update(cx, |_, cx| {
                                cx.emit(AuthEvent::AuthError(
                                    "Failed to prepare access code request".to_string(),
                                ));
                            })
                            .ok();
                    }
                    return;
                }
            };

            // Build HTTP request
            let request = match Request::post(&url)
                .header("Content-Type", "application/json")
                .body(AsyncBody::from(body_bytes))
            {
                Ok(req) => req,
                Err(e) => {
                    log::error!("Failed to build access code request: {e}");
                    if let Some(manager) = handle.upgrade() {
                        manager
                            .update(cx, |_, cx| {
                                cx.emit(AuthEvent::AuthError(
                                    "Failed to build access code request".to_string(),
                                ));
                            })
                            .ok();
                    }
                    return;
                }
            };

            // Send request
            let mut response = match http.send(request).await {
                Ok(resp) => resp,
                Err(e) => {
                    log::error!("Access code sign-in request failed: {e}");
                    if let Some(manager) = handle.upgrade() {
                        manager
                            .update(cx, |_, cx| {
                                cx.emit(AuthEvent::AuthError(
                                    "Failed to contact access code endpoint".to_string(),
                                ));
                            })
                            .ok();
                    }
                    return;
                }
            };

            // Read response body
            let mut body = Vec::new();
            if let Err(e) = response.body_mut().read_to_end(&mut body).await {
                log::error!("Failed to read access code response body: {e}");
                if let Some(manager) = handle.upgrade() {
                    manager
                        .update(cx, |_, cx| {
                            cx.emit(AuthEvent::AuthError(
                                "Failed to read access code response".to_string(),
                            ));
                        })
                        .ok();
                }
                return;
            }

            // Handle non-success status
            if !response.status().is_success() {
                log::warn!(
                    "Access code sign-in failed with HTTP status {} and body: {}",
                    response.status(),
                    String::from_utf8_lossy(&body)
                );
                if let Some(manager) = handle.upgrade() {
                    manager
                        .update(cx, |_, cx| {
                            cx.emit(AuthEvent::AuthError(
                                "Invalid or revoked access code".to_string(),
                            ));
                        })
                        .ok();
                }
                return;
            }

            // Parse JSON body
            let json: serde_json::Value = match serde_json::from_slice(&body) {
                Ok(v) => v,
                Err(e) => {
                    log::error!("Failed to parse access code response JSON: {e}");
                    if let Some(manager) = handle.upgrade() {
                        manager
                            .update(cx, |_, cx| {
                                cx.emit(AuthEvent::AuthError(
                                    "Invalid response from access code endpoint".to_string(),
                                ));
                            })
                            .ok();
                    }
                    return;
                }
            };

            if let Some(manager) = handle.upgrade() {
                manager
                    .update(cx, |this, cx| {
                        let user = &json["user"];
                        let api_key =
                            user["id"].as_str().unwrap_or_default().to_string();
                        let email =
                            user["email"].as_str().map(|s: &str| s.to_string());
                        let github_username = user["github_username"]
                            .as_str()
                            .map(|s: &str| s.to_string());
                        let full_name =
                            user["full_name"].as_str().map(|s: &str| s.to_string());
                        let avatar_url =
                            user["avatar_url"].as_str().map(|s: &str| s.to_string());

                        if api_key.is_empty() {
                            cx.emit(AuthEvent::AuthError(
                                "Invalid response from access code endpoint".to_string(),
                            ));
                            return;
                        }

                        this.save_credentials(
                            &api_key,
                            email.as_deref(),
                            github_username.as_deref(),
                            full_name.as_deref(),
                            avatar_url.as_deref(),
                        );

                        this.state.is_authenticated = true;
                        this.state.api_key = Some(api_key);
                        this.state.email = email;
                        this.state.github_username = github_username;
                        this.state.full_name = full_name;
                        this.state.avatar_url = avatar_url;

                        log::info!(
                            "Access code sign-in succeeded for email {:?}, github_username {:?}",
                            this.state.email,
                            this.state.github_username
                        );

                        cx.emit(AuthEvent::SignedIn);
                        cx.notify();
                    })
                    .ok();
            }
        })
        .detach();
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
                self.save_credentials(
                    &key,
                    email.as_deref(),
                    github_username.as_deref(),
                    None,
                    None,
                );

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
        full_name: Option<&str>,
        avatar_url: Option<&str>,
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
            "full_name": full_name,
            "avatar_url": avatar_url,
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
                let full_name = creds["full_name"].as_str().map(String::from);
                let avatar_url = creds["avatar_url"].as_str().map(String::from);

                if api_key.is_some() {
                    self.state.is_authenticated = true;
                    self.state.api_key = api_key;
                    self.state.email = email;
                    self.state.github_username = github_username;
                    self.state.full_name = full_name;
                    self.state.avatar_url = avatar_url;
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
