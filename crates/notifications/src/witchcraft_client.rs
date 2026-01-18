use anyhow::Result;
use futures::{
    channel::mpsc::unbounded,
    stream::{SplitSink, SplitStream},
    AsyncReadExt, FutureExt as _, SinkExt as _, Stream, StreamExt as _, TryStreamExt as _,
};
use gpui::{App, BackgroundExecutor, Task};
use http_client::{AsyncBody, HttpClient, Method, Request};
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use std::{
    pin::Pin,
    sync::Arc,
    time::Duration,
};
use yawc::WebSocket;
use yawc::frame::{FrameView, OpCode};

const WITCHCRAFT_API_URL: &str = "https://witchcraft.insanelabs.org";
const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WitchcraftMessage {
    Connected {
        #[serde(rename = "userId")]
        user_id: String,
        timestamp: String,
        #[serde(default)]
        method: Option<String>, // "polling" or "realtime"
    },
    UnreadNotifications {
        count: usize,
        notifications: Vec<WitchcraftNotification>,
    },
    Notification {
        event: String,
        data: WitchcraftNotification,
    },
    Pong,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WitchcraftNotification {
    pub id: String,
    pub title: String,
    pub message: String,
    #[serde(rename = "type")]
    pub notification_type: String,
    pub priority: u8,
    #[serde(rename = "actionUrl", skip_serializing_if = "Option::is_none")]
    pub action_url: Option<String>,
    #[serde(rename = "actionLabel", skip_serializing_if = "Option::is_none")]
    pub action_label: Option<String>,
    #[serde(rename = "createdAt")]
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WitchcraftOutgoingMessage {
    MarkRead {
        #[serde(rename = "notificationId")]
        notification_id: String,
    },
    Ping,
}

#[derive(Debug, Clone)]
pub struct TokenResponse {
    pub token: String,
    pub websocket_url: String,
}

pub struct WitchcraftNotificationClient {
    http_client: Arc<dyn HttpClient>,
    token: RwLock<Option<String>>,
}

impl WitchcraftNotificationClient {
    pub fn new(http_client: Arc<dyn HttpClient>) -> Self {
        Self {
            http_client,
            token: RwLock::new(None),
        }
    }

    pub fn connect_with_access_code(&self, access_code: String, cx: &App) -> Result<Task<Result<Connection>>> {
        let http_client = self.http_client.clone();
        *self.token.write() = Some(access_code.clone());

        Ok(gpui_tokio::Tokio::spawn_result(cx, async move {
            let token = access_code;

            let ws_url = format!(
                "wss://witchcraft.insanelabs.org/api/notifications/ws?token={}",
                token
            );

            log::info!("[Witchcraft WebSocket] Connecting to: {}", ws_url);
            let ws = WebSocket::connect(ws_url.parse()?).await?;
            log::info!("[Witchcraft WebSocket] Connection established - will keep connection open");

            Ok(Connection::new(ws))
        }))
    }

    pub fn connect(&self, cx: &App) -> Result<Task<Result<Connection>>> {
        // Try to get token from cache first
        let token_guard = self.token.read();
        if let Some(token) = token_guard.clone() {
            return self.connect_with_access_code(token, cx);
        }
        
        // If no cached token, return error - caller should provide access code
        Err(anyhow::anyhow!("No access code provided. Please provide an access code or API key."))
    }
}

pub type MessageStream = Pin<Box<dyn Stream<Item = Result<WitchcraftMessage>>>>;

pub struct Connection {
    tx: SplitSink<WebSocket, FrameView>,
    rx: SplitStream<WebSocket>,
}

impl Connection {
    pub fn new(ws: WebSocket) -> Self {
        let (tx, rx) = ws.split();
        Self { tx, rx }
    }

    pub fn spawn(self, cx: &App) -> (MessageStream, futures::channel::mpsc::UnboundedSender<WitchcraftOutgoingMessage>, Task<()>) {
        let (mut tx, rx) = (self.tx, self.rx);

        let (message_tx, message_rx) = unbounded();
        let (outgoing_tx, mut outgoing_rx) = futures::channel::mpsc::unbounded();

        log::info!("[Witchcraft WebSocket] Created message channels - message_tx will stay alive in handler task");
        
        let executor = cx.background_executor().clone();
        let executor_for_task = executor.clone();
        // Move message_tx into the handler to keep the channel alive
        let handle_io = async move {
            log::info!("[Witchcraft WebSocket] Starting connection handler - keeping connection alive");
            log::info!("[Witchcraft WebSocket] message_tx is alive in handler: {}", !message_tx.is_closed());
            let keepalive_timer = executor.timer(KEEPALIVE_INTERVAL).fuse();
            futures::pin_mut!(keepalive_timer);

            let rx = rx.fuse();
            futures::pin_mut!(rx);

            loop {
                log::debug!("[Witchcraft WebSocket] Waiting for messages (connection alive)");
                futures::select_biased! {
                    _ = keepalive_timer => {
                        log::debug!("[Witchcraft WebSocket] Sending ping (keep-alive)");
                        let ping = WitchcraftOutgoingMessage::Ping;
                        if let Ok(json) = serde_json::to_string(&ping) {
                            if let Err(e) = tx.send(FrameView::text(json.into_bytes())).await {
                                log::error!("[Witchcraft WebSocket] Failed to send ping: {}", e);
                                break;
                            }
                        }
                        keepalive_timer.set(executor.timer(KEEPALIVE_INTERVAL).fuse());
                    }
                    outgoing_msg = outgoing_rx.next() => {
                        match outgoing_msg {
                            Some(msg) => {
                                log::info!("[Witchcraft WebSocket] Sending outgoing message: {:?}", msg);
                                if let Ok(json) = serde_json::to_string(&msg) {
                                    if let Err(e) = tx.send(FrameView::text(json.into_bytes())).await {
                                        log::error!("[Witchcraft WebSocket] Failed to send outgoing message: {}", e);
                                        break;
                                    }
                                } else {
                                    log::error!("[Witchcraft WebSocket] Failed to serialize outgoing message");
                                }
                            }
                            None => {
                                log::info!("[Witchcraft WebSocket] Outgoing sender dropped, closing connection");
                                break;
                            }
                        }
                    }
                    frame = rx.next() => {
                        let Some(frame) = frame else {
                            log::warn!("[Witchcraft WebSocket] Stream ended unexpectedly");
                            break;
                        };

                        match frame.opcode {
                            OpCode::Text => {
                                if let Ok(text) = String::from_utf8(frame.payload.to_vec()) {
                                    log::info!("[Witchcraft WebSocket] Received message: {}", text);
                                    match serde_json::from_str::<WitchcraftMessage>(&text) {
                                        Ok(message) => {
                                            // Log all received messages for debugging
                                            match &message {
                                                WitchcraftMessage::Connected { user_id, method, .. } => {
                                                    log::info!(
                                                        "[Witchcraft WebSocket] Connected - user_id: {}, method: {:?}",
                                                        user_id,
                                                        method
                                                    );
                                                }
                                                WitchcraftMessage::UnreadNotifications { count, .. } => {
                                                    log::info!(
                                                        "[Witchcraft WebSocket] Unread notifications: {}",
                                                        count
                                                    );
                                                }
                                                WitchcraftMessage::Notification { event, data, .. } => {
                                                    log::info!(
                                                        "[Witchcraft WebSocket] New notification - event: {}, id: {}",
                                                        event,
                                                        data.id
                                                    );
                                                }
                                                WitchcraftMessage::Pong => {
                                                    log::debug!("[Witchcraft WebSocket] Received pong (keep-alive)");
                                                    continue;
                                                }
                                            }
                                            if message_tx.unbounded_send(Ok(message)).is_err() {
                                                log::error!("[Witchcraft WebSocket] Failed to send message to channel - receiver dropped!");
                                                break;
                                            }
                                        }
                                        Err(e) => {
                                            // Log the error but don't break the connection
                                            // The server might send messages we don't recognize yet
                                            log::warn!(
                                                "[Witchcraft WebSocket] Failed to parse message: {} - Raw: {}",
                                                e,
                                                text
                                            );
                                            if message_tx.unbounded_send(Err(anyhow::anyhow!(
                                                "Failed to parse message: {}",
                                                e
                                            ))).is_err() {
                                                log::error!("[Witchcraft WebSocket] Failed to send error to channel - receiver dropped!");
                                                break;
                                            }
                                        }
                                    }
                                } else {
                                    log::warn!("[Witchcraft WebSocket] Received non-UTF8 text frame");
                                }
                            }
                            OpCode::Close => {
                                log::info!("[Witchcraft WebSocket] Connection closed by server");
                                break;
                            }
                            OpCode::Ping => {
                                log::debug!("[Witchcraft WebSocket] Received ping from server");
                            }
                            OpCode::Pong => {
                                log::debug!("[Witchcraft WebSocket] Received pong from server");
                            }
                            _ => {
                                log::debug!("[Witchcraft WebSocket] Received frame with opcode: {:?}", frame.opcode);
                            }
                        }
                    }
                }
            }
            log::info!("[Witchcraft WebSocket] Connection handler loop ended - connection closed");
        };

        // Spawn the handler on background thread since it does I/O
        // The message_tx is moved into handle_io, so it will stay alive as long as the task runs
        // IMPORTANT: We must keep the task handle alive, otherwise the task will be cancelled
        // when the handle is dropped. We'll return it so the caller can keep it alive.
        let task = executor_for_task.spawn(handle_io);
        
        log::info!("[Witchcraft WebSocket] Connection handler task spawned on background thread");
        log::info!("[Witchcraft WebSocket] message_tx is now owned by handler task - stream will stay open");
        log::info!("[Witchcraft WebSocket] Task handle must be kept alive to prevent cancellation");
        // Convert background Task to foreground Task by wrapping it
        // The caller should store this task to keep the handler alive
        let foreground_task = cx.spawn(async move |_cx| {
            // Wait for the background task to complete (which it won't until connection closes)
            task.await;
        });
        (message_rx.into_stream().boxed(), outgoing_tx, foreground_task)
    }
}
