use crate::NotificationPanelSettings;
use anyhow::Result;
use channel::ChannelStore;
use client::{ChannelId, Client, Notification, User, UserStore};
use collections::HashMap;
use db::kvp::KEY_VALUE_STORE;
use futures::StreamExt;
use gpui::{
    AnyElement, App, AsyncWindowContext, ClickEvent, Context, DismissEvent, Element, Entity,
    EventEmitter, FocusHandle, Focusable, InteractiveElement, IntoElement, ListAlignment,
    ListScrollEvent, ListState, ParentElement, Render, StatefulInteractiveElement, Styled, Task,
    WeakEntity, Window, actions, div, img, list, px,
};
use notifications::{
    NotificationEntry, NotificationEvent, NotificationStore, WitchcraftNotification,
    WitchcraftNotificationClient,
};
use project::Fs;
use rpc::proto;
use serde::{Deserialize, Serialize};
use settings::{Settings, SettingsStore};
use std::{sync::Arc, time::Duration};
use time::{OffsetDateTime, UtcOffset};
use ui::{
    Avatar, Button, Icon, IconButton, IconName, Label, LabelSize, SpinnerLabel, Tab, Tooltip, h_flex, prelude::*, v_flex,
};
use util::{ResultExt, TryFutureExt};
use workspace::notifications::{
    Notification as WorkspaceNotification, NotificationId, SuppressEvent,
};
use workspace::{
    Workspace,
    dock::{DockPosition, Panel, PanelEvent},
};

const LOADING_THRESHOLD: usize = 30;
const MARK_AS_READ_DELAY: Duration = Duration::from_secs(1);
const TOAST_DURATION: Duration = Duration::from_secs(5);
const NOTIFICATION_PANEL_KEY: &str = "NotificationPanel";

pub struct NotificationPanel {
    client: Arc<Client>,
    user_store: Entity<UserStore>,
    channel_store: Entity<ChannelStore>,
    notification_store: Entity<NotificationStore>,
    witchcraft_client: Arc<WitchcraftNotificationClient>,
    witchcraft_connection: Option<Task<Result<()>>>,
    witchcraft_notifications: Vec<WitchcraftNotification>,
    witchcraft_sender: Option<futures::channel::mpsc::UnboundedSender<notifications::WitchcraftOutgoingMessage>>,
    fs: Arc<dyn Fs>,
    width: Option<Pixels>,
    active: bool,
    notification_list: ListState,
    pending_serialization: Task<Option<()>>,
    subscriptions: Vec<gpui::Subscription>,
    workspace: WeakEntity<Workspace>,
    current_notification_toast: Option<(u64, Task<()>)>,
    local_timezone: UtcOffset,
    focus_handle: FocusHandle,
    mark_as_read_tasks: HashMap<u64, Task<Result<()>>>,
    unseen_notifications: Vec<NotificationEntry>,
    witchcraft_connected: bool,
    witchcraft_handler_task: Option<Task<()>>, // Keep the handler task alive
    witchcraft_connecting: bool, // Track connection state for loading indicator
}

#[derive(Serialize, Deserialize)]
struct SerializedNotificationPanel {
    width: Option<Pixels>,
}

#[derive(Debug)]
pub enum Event {
    DockPositionChanged,
    Focus,
    Dismissed,
}

pub struct NotificationPresenter {
    pub actor: Option<Arc<client::User>>,
    pub text: String,
    pub icon: &'static str,
    pub needs_response: bool,
}

actions!(
    notification_panel,
    [
        /// Toggles focus on the notification panel.
        ToggleFocus
    ]
);

pub fn init(cx: &mut App) {
    cx.observe_new(|workspace: &mut Workspace, _, _| {
        workspace.register_action(|workspace, _: &ToggleFocus, window, cx| {
            workspace.toggle_panel_focus::<NotificationPanel>(window, cx);
        });
    })
    .detach();
}

impl NotificationPanel {
    pub fn new(
        workspace: &mut Workspace,
        window: &mut Window,
        cx: &mut Context<Workspace>,
    ) -> Entity<Self> {
        let fs = workspace.app_state().fs.clone();
        let client = workspace.app_state().client.clone();
        let user_store = workspace.app_state().user_store.clone();
        let workspace_handle = workspace.weak_handle();

        cx.new(|cx| {
            let mut status = client.status();
            cx.spawn_in(window, async move |this, cx| {
                while (status.next().await).is_some() {
                    if this
                        .update(cx, |_: &mut Self, cx| {
                            cx.notify();
                        })
                        .is_err()
                    {
                        break;
                    }
                }
            })
            .detach();

            let notification_list = ListState::new(0, ListAlignment::Top, px(1000.));
            notification_list.set_scroll_handler(cx.listener(
                |this, event: &ListScrollEvent, _, cx| {
                    if event.count.saturating_sub(event.visible_range.end) < LOADING_THRESHOLD
                        && let Some(task) = this
                            .notification_store
                            .update(cx, |store, cx| store.load_more_notifications(false, cx))
                    {
                        task.detach();
                    }
                },
            ));

            let local_offset = chrono::Local::now().offset().local_minus_utc();
            let http_client = cx.http_client();
            let witchcraft_client = Arc::new(WitchcraftNotificationClient::new(http_client));
            let mut this = Self {
                fs,
                client,
                user_store,
                local_timezone: UtcOffset::from_whole_seconds(local_offset).unwrap(),
                channel_store: ChannelStore::global(cx),
                notification_store: NotificationStore::global(cx),
                witchcraft_client: witchcraft_client.clone(),
                witchcraft_connection: None,
                witchcraft_notifications: Vec::new(),
                witchcraft_sender: None,
                notification_list,
                pending_serialization: Task::ready(None),
                workspace: workspace_handle,
                focus_handle: cx.focus_handle(),
                current_notification_toast: None,
                subscriptions: Vec::new(),
                active: false,
                mark_as_read_tasks: HashMap::default(),
                width: None,
                unseen_notifications: Vec::new(),
                witchcraft_connected: false,
                witchcraft_handler_task: None,
                witchcraft_connecting: false,
            };
            
            // Auto-connect to witchcraft notifications on startup
            let witchcraft_client_clone = witchcraft_client.clone();
            let entity_clone = cx.entity();
            cx.defer(move |cx| {
                let witchcraft_client = witchcraft_client_clone.clone();
                let entity = entity_clone.clone();
                // Get access code from credentials file
                let credentials_path = dirs::config_dir()
                    .unwrap_or_else(|| std::path::PathBuf::from("."))
                    .join("witchcraft")
                    .join("credentials.json");
                
                let access_code = std::fs::read_to_string(&credentials_path)
                    .ok()
                    .and_then(|contents| {
                        serde_json::from_str::<serde_json::Value>(&contents).ok()
                    })
                    .and_then(|creds| {
                        creds["access_code"].as_str().map(String::from)
                    });
                
                if let Some(access_code) = access_code {
                    entity.update(cx, |this, cx| {
                        this.witchcraft_connecting = true;
                        cx.notify();
                    });
                    
                    // Trigger the connect button logic programmatically
                    // We'll reuse the existing connect button handler
                    let connect_task = witchcraft_client.connect_with_access_code(access_code, cx);
                    if let Ok(task) = connect_task {
                        let entity_for_task = entity.clone();
                        cx.spawn(async move |cx| {
                            match task.await {
                                Ok(connection) => {
                                    entity_for_task.update(cx, |this, cx| {
                                        this.witchcraft_connecting = false;
                                        let (mut messages, sender, task) = connection.spawn(cx);
                                        this.witchcraft_sender = Some(sender);
                                        this.witchcraft_handler_task = Some(task);
                                        cx.notify();
                                        
                                        // Start message receiver loop for auto-connect
                                        let entity_for_loop = entity_for_task.clone();
                                        let workspace_handle = this.workspace.clone();
                                        cx.spawn(async move |_this, cx| {
                                            log::info!("[Witchcraft NotificationPanel] Auto-connected, starting message receiver loop");
                                            while let Some(message_result) = messages.next().await {
                                                match message_result {
                                                    Ok(message) => {
                                                        entity_for_loop.update(cx, |this, cx| {
                                                            match message {
                                                                notifications::WitchcraftMessage::Connected { user_id, method, .. } => {
                                                                    log::info!("[Witchcraft NotificationPanel] Auto-connected - user_id: {}, method: {:?}", user_id, method);
                                                                    this.witchcraft_connected = true;
                                                                    cx.notify();
                                                                }
                                                                notifications::WitchcraftMessage::UnreadNotifications { count, notifications, .. } => {
                                                                    log::info!("[Witchcraft NotificationPanel] Received {} unread notifications on auto-connect", count);
                                                                    for notif in notifications {
                                                                        if !this.witchcraft_notifications.iter().any(|n| n.id == notif.id) {
                                                                            this.witchcraft_notifications.push(notif);
                                                                        }
                                                                    }
                                                                    cx.notify();
                                                                }
                                                                notifications::WitchcraftMessage::Notification { event, data, .. } => {
                                                                    log::info!("[Witchcraft NotificationPanel] New notification - event: {}, id: {}", event, data.id);
                                                                    // Deduplicate by notification ID
                                                                    if !this.witchcraft_notifications.iter().any(|n| n.id == data.id) {
                                                                        this.witchcraft_notifications.push(data.clone());
                                                                        // Show toast notification for new messages via workspace
                                                                        let workspace_handle_for_toast = workspace_handle.clone();
                                                                        let toast_data = data.clone();
                                                                        if let Some(workspace) = workspace_handle_for_toast.upgrade() {
                                                                            let _ = workspace.update(cx, |workspace, cx| {
                                                                                workspace.show_toast(
                                                                                    workspace::Toast::new(
                                                                                        workspace::notifications::NotificationId::unique::<Self>(),
                                                                                        format!("{}: {}", toast_data.title, toast_data.message),
                                                                                    )
                                                                                    .autohide(),
                                                                                    cx,
                                                                                );
                                                                            });
                                                                        }
                                                                    }
                                                                    cx.notify();
                                                                }
                                                                notifications::WitchcraftMessage::Pong => {
                                                                    // Silently handle pong
                                                                }
                                                            }
                                                        }).ok();
                                                    }
                                                    Err(e) => {
                                                        log::error!("[Witchcraft NotificationPanel] Error receiving message: {}", e);
                                                    }
                                                }
                                            }
                                            log::warn!("[Witchcraft NotificationPanel] Auto-connect message receiver loop ended");
                                        }).detach();
                                    }).ok();
                                }
                                Err(e) => {
                                    log::error!("[Witchcraft NotificationPanel] Auto-connect failed: {}", e);
                                    entity_for_task.update(cx, |this, cx| {
                                        this.witchcraft_connecting = false;
                                        cx.notify();
                                    }).ok();
                                }
                            }
                        }).detach();
                    } else {
                        entity.update(cx, |this, cx| {
                            this.witchcraft_connecting = false;
                            cx.notify();
                        });
                    }
                }
            });

            let mut old_dock_position = this.position(window, cx);
            this.subscriptions.extend([
                cx.observe(&this.notification_store, |_, _, cx| cx.notify()),
                cx.subscribe_in(
                    &this.notification_store,
                    window,
                    Self::on_notification_event,
                ),
                cx.observe_global_in::<SettingsStore>(
                    window,
                    move |this: &mut Self, window, cx| {
                        let new_dock_position = this.position(window, cx);
                        if new_dock_position != old_dock_position {
                            old_dock_position = new_dock_position;
                            cx.emit(Event::DockPositionChanged);
                        }
                        cx.notify();
                    },
                ),
            ]);
            this
        })
    }

    pub fn load(
        workspace: WeakEntity<Workspace>,
        cx: AsyncWindowContext,
    ) -> Task<Result<Entity<Self>>> {
        cx.spawn(async move |cx| {
            let serialized_panel = if let Some(panel) = cx
                .background_spawn(async move { KEY_VALUE_STORE.read_kvp(NOTIFICATION_PANEL_KEY) })
                .await
                .log_err()
                .flatten()
            {
                Some(serde_json::from_str::<SerializedNotificationPanel>(&panel)?)
            } else {
                None
            };

            workspace.update_in(cx, |workspace, window, cx| {
                let panel = Self::new(workspace, window, cx);
                if let Some(serialized_panel) = serialized_panel {
                    panel.update(cx, |panel, cx| {
                        panel.width = serialized_panel.width.map(|w| w.round());
                        cx.notify();
                    });
                }
                panel
            })
        })
    }

    fn serialize(&mut self, cx: &mut Context<Self>) {
        let width = self.width;
        self.pending_serialization = cx.background_spawn(
            async move {
                KEY_VALUE_STORE
                    .write_kvp(
                        NOTIFICATION_PANEL_KEY.into(),
                        serde_json::to_string(&SerializedNotificationPanel { width })?,
                    )
                    .await?;
                anyhow::Ok(())
            }
            .log_err(),
        );
    }

    fn render_notification(
        &mut self,
        ix: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let entry = self.notification_store.read(cx).notification_at(ix)?;
        let notification_id = entry.id;
        let now = OffsetDateTime::now_utc();
        let timestamp = entry.timestamp;
        let NotificationPresenter {
            actor,
            text,
            needs_response,
            ..
        } = self.present_notification(entry, cx)?;

        let response = entry.response;
        let notification = entry.notification.clone();

        if self.active && !entry.is_read {
            self.did_render_notification(notification_id, &notification, window, cx);
        }

        let relative_timestamp = time_format::format_localized_timestamp(
            timestamp,
            now,
            self.local_timezone,
            time_format::TimestampFormat::Relative,
        );

        let absolute_timestamp = time_format::format_localized_timestamp(
            timestamp,
            now,
            self.local_timezone,
            time_format::TimestampFormat::Absolute,
        );

        Some(
            div()
                .id(ix)
                .flex()
                .flex_row()
                .size_full()
                .px_2()
                .py_1()
                .gap_2()
                .hover(|style| style.bg(cx.theme().colors().element_hover))
                .children(actor.map(|actor| {
                    img(actor.avatar_uri.clone())
                        .flex_none()
                        .w_8()
                        .h_8()
                        .rounded_full()
                }))
                .child(
                    v_flex()
                        .gap_1()
                        .size_full()
                        .overflow_hidden()
                        .child(Label::new(text))
                        .child(
                            h_flex()
                                .child(
                                    div()
                                        .id("notification_timestamp")
                                        .hover(|style| {
                                            style
                                                .bg(cx.theme().colors().element_selected)
                                                .rounded_sm()
                                        })
                                        .child(Label::new(relative_timestamp).color(Color::Muted))
                                        .tooltip(move |_, cx| {
                                            Tooltip::simple(absolute_timestamp.clone(), cx)
                                        }),
                                )
                                .children(if let Some(is_accepted) = response {
                                    Some(div().flex().flex_grow().justify_end().child(Label::new(
                                        if is_accepted {
                                            "You accepted"
                                        } else {
                                            "You declined"
                                        },
                                    )))
                                } else if needs_response {
                                    Some(
                                        h_flex()
                                            .flex_grow()
                                            .justify_end()
                                            .child(Button::new("decline", "Decline").on_click({
                                                let notification = notification.clone();
                                                let entity = cx.entity();
                                                move |_, _, cx| {
                                                    entity.update(cx, |this, cx| {
                                                        this.respond_to_notification(
                                                            notification.clone(),
                                                            false,
                                                            cx,
                                                        )
                                                    });
                                                }
                                            }))
                                            .child(Button::new("accept", "Accept").on_click({
                                                let notification = notification.clone();
                                                let entity = cx.entity();
                                                move |_, _, cx| {
                                                    entity.update(cx, |this, cx| {
                                                        this.respond_to_notification(
                                                            notification.clone(),
                                                            true,
                                                            cx,
                                                        )
                                                    });
                                                }
                                            })),
                                    )
                                } else {
                                    None
                                }),
                        ),
                )
                .into_any(),
        )
    }

    fn render_witchcraft_notification(
        &self,
        ix: usize,
        notif: &WitchcraftNotification,
        cx: &App,
    ) -> AnyElement {
        // Parse the created_at timestamp
        let timestamp = time::OffsetDateTime::parse(&notif.created_at, &time::format_description::well_known::Rfc3339)
            .ok()
            .unwrap_or_else(|| time::OffsetDateTime::now_utc());
        
        let now = OffsetDateTime::now_utc();
        let relative_timestamp = time_format::format_localized_timestamp(
            timestamp,
            now,
            self.local_timezone,
            time_format::TimestampFormat::Relative,
        );
        
        let absolute_timestamp = time_format::format_localized_timestamp(
            timestamp,
            now,
            self.local_timezone,
            time_format::TimestampFormat::Absolute,
        );
        
        // Determine icon based on notification type
        let icon_name = match notif.notification_type.as_str() {
            "success" => IconName::Check,
            "warning" => IconName::Warning,
            "error" => IconName::XCircle,
            _ => IconName::Info,
        };
        
        div()
            .id(format!("witchcraft_{}", ix))
            .flex()
            .flex_row()
            .size_full()
            .px_2()
            .py_1()
            .gap_2()
            .hover(|style| style.bg(cx.theme().colors().element_hover))
            .child(
                Icon::new(icon_name)
                    .color(Color::Muted)
            )
            .child(
                v_flex()
                    .gap_1()
                    .size_full()
                    .overflow_hidden()
                    .child(Label::new(notif.title.clone()).size(LabelSize::Small))
                    .child(Label::new(notif.message.clone()).color(Color::Muted).size(LabelSize::Small))
                    .child(
                        h_flex()
                            .child(
                                div()
                                    .id("witchcraft_notification_timestamp")
                                    .hover(|style| {
                                        style
                                            .bg(cx.theme().colors().element_selected)
                                            .rounded_sm()
                                    })
                                    .child(Label::new(relative_timestamp).color(Color::Muted).size(LabelSize::Small))
                                    .tooltip(move |_, cx| {
                                        Tooltip::simple(absolute_timestamp.clone(), cx)
                                    }),
                            )
                            .when_some(notif.action_url.clone(), |this, url| {
                                this.child(
                                    Button::new(format!("action_{}", ix), notif.action_label.as_ref().unwrap_or(&"View".to_string()))
                                        .on_click({
                                            let url = url.clone();
                                            move |_, _, _| {
                                                log::info!("Opening action URL: {}", url);
                                            }
                                        })
                                )
                            }),
                    ),
            )
            .into_any()
    }

    fn present_notification(
        &self,
        entry: &NotificationEntry,
        cx: &App,
    ) -> Option<NotificationPresenter> {
        let user_store = self.user_store.read(cx);
        let channel_store = self.channel_store.read(cx);
        match entry.notification {
            Notification::ContactRequest { sender_id } => {
                let requester = user_store.get_cached_user(sender_id)?;
                Some(NotificationPresenter {
                    icon: "icons/plus.svg",
                    text: format!("{} wants to add you as a contact", requester.github_login),
                    needs_response: user_store.has_incoming_contact_request(requester.id),
                    actor: Some(requester),
                })
            }
            Notification::ContactRequestAccepted { responder_id } => {
                let responder = user_store.get_cached_user(responder_id)?;
                Some(NotificationPresenter {
                    icon: "icons/plus.svg",
                    text: format!("{} accepted your contact invite", responder.github_login),
                    needs_response: false,
                    actor: Some(responder),
                })
            }
            Notification::ChannelInvitation {
                ref channel_name,
                channel_id,
                inviter_id,
            } => {
                let inviter = user_store.get_cached_user(inviter_id)?;
                Some(NotificationPresenter {
                    icon: "icons/hash.svg",
                    text: format!(
                        "{} invited you to join the #{channel_name} channel",
                        inviter.github_login
                    ),
                    needs_response: channel_store.has_channel_invitation(ChannelId(channel_id)),
                    actor: Some(inviter),
                })
            }
        }
    }

    fn did_render_notification(
        &mut self,
        notification_id: u64,
        notification: &Notification,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let should_mark_as_read = match notification {
            Notification::ContactRequestAccepted { .. } => true,
            Notification::ContactRequest { .. } | Notification::ChannelInvitation { .. } => false,
        };

        if should_mark_as_read {
            self.mark_as_read_tasks
                .entry(notification_id)
                .or_insert_with(|| {
                    let client = self.client.clone();
                    cx.spawn_in(window, async move |this, cx| {
                        cx.background_executor().timer(MARK_AS_READ_DELAY).await;
                        client
                            .request(proto::MarkNotificationRead { notification_id })
                            .await?;
                        this.update(cx, |this, _| {
                            this.mark_as_read_tasks.remove(&notification_id);
                        })?;
                        Ok(())
                    })
                });
        }
    }

    fn on_notification_event(
        &mut self,
        _: &Entity<NotificationStore>,
        event: &NotificationEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match event {
            NotificationEvent::NewNotification { entry } => {
                self.unseen_notifications.push(entry.clone());
                self.add_toast(entry, window, cx);
            }
            NotificationEvent::NotificationRemoved { entry }
            | NotificationEvent::NotificationRead { entry } => {
                self.unseen_notifications.retain(|n| n.id != entry.id);
                self.remove_toast(entry.id, cx);
            }
            NotificationEvent::NotificationsUpdated {
                old_range,
                new_count,
            } => {
                self.notification_list.splice(old_range.clone(), *new_count);
                cx.notify();
            }
        }
    }

    fn add_toast(
        &mut self,
        entry: &NotificationEntry,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(NotificationPresenter { actor, text, .. }) = self.present_notification(entry, cx)
        else {
            return;
        };

        let notification_id = entry.id;
        self.current_notification_toast = Some((
            notification_id,
            cx.spawn_in(window, async move |this, cx| {
                cx.background_executor().timer(TOAST_DURATION).await;
                this.update(cx, |this, cx| this.remove_toast(notification_id, cx))
                    .ok();
            }),
        ));

        self.workspace
            .update(cx, |workspace, cx| {
                let id = NotificationId::unique::<NotificationToast>();

                workspace.dismiss_notification(&id, cx);
                workspace.show_notification(id, cx, |cx| {
                    let workspace = cx.entity().downgrade();
                    cx.new(|cx| NotificationToast {
                        actor,
                        text,
                        workspace,
                        focus_handle: cx.focus_handle(),
                    })
                })
            })
            .ok();
    }

    fn remove_toast(&mut self, notification_id: u64, cx: &mut Context<Self>) {
        if let Some((current_id, _)) = &self.current_notification_toast
            && *current_id == notification_id
        {
            self.current_notification_toast.take();
            self.workspace
                .update(cx, |workspace, cx| {
                    let id = NotificationId::unique::<NotificationToast>();
                    workspace.dismiss_notification(&id, cx)
                })
                .ok();
        }
    }

    fn respond_to_notification(
        &mut self,
        notification: Notification,
        response: bool,

        cx: &mut Context<Self>,
    ) {
        self.notification_store.update(cx, |store, cx| {
            store.respond_to_notification(notification, response, cx);
        });
    }
}

impl Render for NotificationPanel {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .size_full()
            .child(
                h_flex()
                    .justify_between()
                    .px_2()
                    .py_1()
                    // Match the height of the tab bar so they line up.
                    .h(Tab::container_height(cx))
                    .border_b_1()
                    .border_color(cx.theme().colors().border)
                    .child(Label::new("Notifications"))
                    .child(Icon::new(IconName::Envelope)),
            )
            .map(|this| {
                let show_connect = !self.client.status().borrow().is_connected()
                    && !self.witchcraft_connected
                    && !self.witchcraft_connecting;
                let show_witchcraft_connect = !self.witchcraft_connected && !self.witchcraft_connecting;
                let show_witchcraft_loading = self.witchcraft_connecting;

                if show_connect || show_witchcraft_connect || show_witchcraft_loading {
                    this.child(
                        v_flex()
                            .gap_2()
                            .p_4()
                            .when(show_witchcraft_loading, |this| {
                                this.child(
                                    v_flex()
                                        .gap_2()
                                        .items_center()
                                        .child(
                                            SpinnerLabel::new()
                                                .color(Color::Muted)
                                        )
                                        .child(
                                            Label::new("Connecting to notifications...")
                                                .color(Color::Muted)
                                                .size(LabelSize::Small)
                                        )
                                )
                            })
                            .when(show_witchcraft_connect, |this| {
                                this.child(
                                    Button::new("connect_witchcraft_button", "Connect")
                                        .icon_color(Color::Muted)
                                        .icon(IconName::Bell)
                                        .icon_position(IconPosition::Start)
                                        .style(ButtonStyle::Filled)
                                        .full_width()
                                        .on_click({
                                            let witchcraft_client = self.witchcraft_client.clone();
                                            let entity = cx.entity();
                                            move |_, window, cx| {
                                                let witchcraft_client = witchcraft_client.clone();
                                                let entity = entity.clone();
                                                
                                                // Get access code from credentials file (stored after login)
                                                let credentials_path = dirs::config_dir()
                                                    .unwrap_or_else(|| std::path::PathBuf::from("."))
                                                    .join("witchcraft")
                                                    .join("credentials.json");
                                                
                                                let access_code = std::fs::read_to_string(&credentials_path)
                                                    .ok()
                                                    .and_then(|contents| {
                                                        serde_json::from_str::<serde_json::Value>(&contents).ok()
                                                    })
                                                    .and_then(|creds| {
                                                        creds["access_code"].as_str().map(String::from)
                                                    });
                                                
                                                let Some(access_code) = access_code else {
                                                    log::error!("Not authenticated. Please sign in first.");
                                                    return;
                                                };
                                                
                                                let connect_task = match witchcraft_client.connect_with_access_code(access_code, cx) {
                                                    Ok(task) => task,
                                                    Err(e) => {
                                                        log::error!("Failed to start connection: {}", e);
                                                        return;
                                                    }
                                                };
                                                window
                                                    .spawn(cx, async move |cx| {
                                                        match connect_task.await {
                                                            Ok(connection) => {
                                                                cx.update(|_, cx| {
                                                                    let (mut messages, sender, task) =
                                                                        connection.spawn(cx);
                                                                    // Store the task in the entity to keep the handler alive
                                                                    // If the task is dropped, the handler will be cancelled and the stream will end
                                                                    entity.update(cx, |this, cx| {
                                                                        this.witchcraft_handler_task = Some(task);
                                                                        cx.notify();
                                                                    });
                                                                    let entity = entity.clone();
                                                                    let entity_for_sender = entity.clone();
                                                                    entity_for_sender.update(cx, |this, cx| {
                                                                        this.witchcraft_sender = Some(sender);
                                                                        cx.notify();
                                                                    });
                                                                    log::info!("[Witchcraft NotificationPanel] Starting message receiver loop - connection will stay open");
                                                                    log::info!("[Witchcraft NotificationPanel] Message stream created, waiting for messages...");
                                                                    cx.spawn(async move |cx| {
                                                                    log::info!("[Witchcraft NotificationPanel] Message receiver task started");
                                                                    while let Some(
                                                                        message_result,
                                                                    ) = messages.next().await
                                                                    {
                                                                        log::debug!("[Witchcraft NotificationPanel] Got message from stream");
                                                                        match message_result {
                                                                            Ok(message) => {
                                                                                log::info!("[Witchcraft NotificationPanel] Processing message: {:?}", message);
                                                                                entity
                                                                                    .update(
                                                                                        cx,
                                                                                        |this,
                                                                                         cx| {
                                                                                            match message
                                                                                            {
                                                                                                notifications::WitchcraftMessage::Connected {
                                                                                                    user_id,
                                                                                                    method,
                                                                                                    ..
                                                                                                } => {
                                                                                                    log::info!(
                                                                                                        "[Witchcraft NotificationPanel] Connected - user_id: {}, method: {:?} - KEEPING CONNECTION OPEN",
                                                                                                        user_id,
                                                                                                        method
                                                                                                    );
                                                                                                    this.witchcraft_connected =
                                                                                                        true;
                                                                                                    cx.notify();
                                                                                                    // Connection stays open - do NOT close here
                                                                                                }
                                                                                                notifications::WitchcraftMessage::UnreadNotifications {
                                                                                                    count,
                                                                                                    notifications,
                                                                                                    ..
                                                                                                } => {
                                                                                                    log::info!(
                                                                                                        "[Witchcraft NotificationPanel] Received {} unread notifications - KEEPING CONNECTION OPEN",
                                                                                                        count
                                                                                                    );
                                                                                                    // Deduplicate by notification ID to avoid duplicates
                                                                                                    for notif in notifications {
                                                                                                        if !this.witchcraft_notifications.iter().any(|n| n.id == notif.id) {
                                                                                                            this.witchcraft_notifications.push(notif);
                                                                                                        }
                                                                                                    }
                                                                                                    cx.notify();
                                                                                                    // Connection stays open - do NOT close here
                                                                                                }
                                                                                                notifications::WitchcraftMessage::Notification {
                                                                                                    event,
                                                                                                    data,
                                                                                                    ..
                                                                                                } => {
                                                                                                    log::info!(
                                                                                                        "[Witchcraft NotificationPanel] New notification - event: {}, id: {} - KEEPING CONNECTION OPEN",
                                                                                                        event,
                                                                                                        data.id
                                                                                                    );
                                                                                                    // Deduplicate by notification ID
                                                                                                    if !this.witchcraft_notifications.iter().any(|n| n.id == data.id) {
                                                                                                        this.witchcraft_notifications.push(data.clone());
                                                                                                        // Show toast notification for new messages via workspace
                                                                                                        let workspace_handle = this.workspace.clone();
                                                                                                        let toast_data = data.clone();
                                                                                                        if let Some(workspace) = workspace_handle.upgrade() {
                                                                                                            let _ = workspace.update(cx, |workspace, cx| {
                                                                                                                workspace.show_toast(
                                                                                                                    workspace::Toast::new(
                                                                                                                        workspace::notifications::NotificationId::unique::<Self>(),
                                                                                                                        format!("{}: {}", toast_data.title, toast_data.message),
                                                                                                                    )
                                                                                                                    .autohide(),
                                                                                                                    cx,
                                                                                                                );
                                                                                                            });
                                                                                                        }
                                                                                                    }
                                                                                                    cx.notify();
                                                                                                    // Connection stays open - do NOT close here
                                                                                                }
                                                                                                notifications::WitchcraftMessage::Pong => {
                                                                                                    log::debug!("[Witchcraft NotificationPanel] Received pong (keep-alive response)");
                                                                                                    // Silently handle pong (keep-alive response)
                                                                                                }
                                                                                            }
                                                                                        },
                                                                                    )
                                                                                    .ok();
                                                                            }
                                                                            Err(e) => {
                                                                                log::error!(
                                                                                    "[Witchcraft NotificationPanel] Error receiving message: {} - KEEPING CONNECTION OPEN",
                                                                                                                    e
                                                                                                                );
                                                                                                                // Don't break on error - keep connection open
                                                                            }
                                                                        }
                                                                    }
                                                                    log::warn!("[Witchcraft NotificationPanel] Message receiver loop ended - connection may have closed");
                                                                    })
                                                                    .detach();
                                                                })
                                                                .ok();
                                                            }
                                                            Err(e) => {
                                                                log::error!(
                                                                    "Failed to connect: {}",
                                                                    e
                                                                );
                                                            }
                                                        }
                                                    })
                                                    .detach();
                                            }
                                        }),
                                )
                            })
                            .when(show_connect, |this| {
                                this.child(
                                    Button::new("connect_prompt_button", "Connect")
                                        .icon_color(Color::Muted)
                                        .icon(IconName::Github)
                                        .icon_position(IconPosition::Start)
                                        .style(ButtonStyle::Filled)
                                        .full_width()
                                        .on_click({
                                            let client = self.client.clone();
                                            move |_, window, cx| {
                                                let client = client.clone();
                                                window
                                                    .spawn(cx, async move |cx| {
                                                        match client.connect(true, cx).await {
                                                            util::ConnectionResult::Timeout => {
                                                                log::error!("Connection timeout");
                                                            }
                                                            util::ConnectionResult::ConnectionReset => {
                                                                log::error!("Connection reset");
                                                            }
                                                            util::ConnectionResult::Result(r) => {
                                                                r.log_err();
                                                            }
                                                        }
                                                    })
                                                    .detach()
                                            }
                                        }),
                                )
                            })
                            .child(
                                div().flex().w_full().items_center().child(
                                    Label::new("Connect to view notifications.")
                                        .color(Color::Muted)
                                        .size(LabelSize::Small),
                                ),
                            ),
                    )
                } else if self.notification_list.item_count() == 0
                    && self.witchcraft_notifications.is_empty()
                {
                    this.child(
                        v_flex().p_4().child(
                            div().flex().w_full().items_center().child(
                                Label::new("You have no notifications.")
                                    .color(Color::Muted)
                                    .size(LabelSize::Small),
                            ),
                        ),
                    )
                } else {
                    let witchcraft_count = self.witchcraft_notifications.len();
                    let regular_count = self.notification_list.item_count();
                    
                    this.child(
                        v_flex()
                            .size_full()
                            .child(
                                // Render witchcraft notifications first
                                v_flex()
                                    .children(self.witchcraft_notifications.iter().enumerate().map(|(ix, notif)| {
                                        self.render_witchcraft_notification(ix, notif, cx)
                                    }))
                            )
                            .child(
                                // Then render regular notifications in a list
                                if regular_count > 0 {
                                    list(
                                        self.notification_list.clone(),
                                        cx.processor(|this, ix, window, cx| {
                                            this.render_notification(ix, window, cx)
                                                .unwrap_or_else(|| div().into_any())
                                        }),
                                    )
                                    .size_full()
                                    .into_any()
                                } else {
                                    div().into_any()
                                }
                            )
                    )
                }
            })
    }
}

impl Focusable for NotificationPanel {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl EventEmitter<Event> for NotificationPanel {}
impl EventEmitter<PanelEvent> for NotificationPanel {}

impl Panel for NotificationPanel {
    fn persistent_name() -> &'static str {
        "NotificationPanel"
    }

    fn panel_key() -> &'static str {
        NOTIFICATION_PANEL_KEY
    }

    fn position(&self, _: &Window, cx: &App) -> DockPosition {
        NotificationPanelSettings::get_global(cx).dock
    }

    fn position_is_valid(&self, position: DockPosition) -> bool {
        matches!(position, DockPosition::Left | DockPosition::Right)
    }

    fn set_position(&mut self, position: DockPosition, _: &mut Window, cx: &mut Context<Self>) {
        settings::update_settings_file(self.fs.clone(), cx, move |settings, _| {
            settings.notification_panel.get_or_insert_default().dock = Some(position.into())
        });
    }

    fn size(&self, _: &Window, cx: &App) -> Pixels {
        self.width
            .unwrap_or_else(|| NotificationPanelSettings::get_global(cx).default_width)
    }

    fn set_size(&mut self, size: Option<Pixels>, _: &mut Window, cx: &mut Context<Self>) {
        self.width = size;
        self.serialize(cx);
        cx.notify();
    }

    fn set_active(&mut self, active: bool, _: &mut Window, cx: &mut Context<Self>) {
        self.active = active;

        if self.active {
            self.unseen_notifications = Vec::new();
            cx.notify();
        }

        if self.notification_store.read(cx).notification_count() == 0 {
            cx.emit(Event::Dismissed);
        }
    }

    fn icon(&self, _: &Window, cx: &App) -> Option<IconName> {
        let show_button = NotificationPanelSettings::get_global(cx).button;
        if !show_button {
            return None;
        }

        if self.unseen_notifications.is_empty() {
            return Some(IconName::Bell);
        }

        Some(IconName::BellDot)
    }

    fn icon_tooltip(&self, _window: &Window, _cx: &App) -> Option<&'static str> {
        Some("Notification Panel")
    }

    fn icon_label(&self, _window: &Window, cx: &App) -> Option<String> {
        let count = self.notification_store.read(cx).unread_notification_count();
        if count == 0 {
            None
        } else {
            Some(count.to_string())
        }
    }

    fn toggle_action(&self) -> Box<dyn gpui::Action> {
        Box::new(ToggleFocus)
    }

    fn activation_priority(&self) -> u32 {
        8
    }
}

pub struct NotificationToast {
    actor: Option<Arc<User>>,
    text: String,
    workspace: WeakEntity<Workspace>,
    focus_handle: FocusHandle,
}

impl Focusable for NotificationToast {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl WorkspaceNotification for NotificationToast {}

impl NotificationToast {
    fn focus_notification_panel(&self, window: &mut Window, cx: &mut Context<Self>) {
        let workspace = self.workspace.clone();
        window.defer(cx, move |window, cx| {
            workspace
                .update(cx, |workspace, cx| {
                    workspace.focus_panel::<NotificationPanel>(window, cx)
                })
                .ok();
        })
    }
}

impl Render for NotificationToast {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let user = self.actor.clone();

        let suppress = window.modifiers().shift;
        let (close_id, close_icon) = if suppress {
            ("suppress", IconName::Minimize)
        } else {
            ("close", IconName::Close)
        };

        h_flex()
            .id("notification_panel_toast")
            .elevation_3(cx)
            .p_2()
            .justify_between()
            .children(user.map(|user| Avatar::new(user.avatar_uri.clone())))
            .child(Label::new(self.text.clone()))
            .on_modifiers_changed(cx.listener(|_, _, _, cx| cx.notify()))
            .child(
                IconButton::new(close_id, close_icon)
                    .tooltip(move |_window, cx| {
                        if suppress {
                            Tooltip::for_action(
                                "Suppress.\nClose with click.",
                                &workspace::SuppressNotification,
                                cx,
                            )
                        } else {
                            Tooltip::for_action(
                                "Close.\nSuppress with shift-click",
                                &menu::Cancel,
                                cx,
                            )
                        }
                    })
                    .on_click(cx.listener(move |_, _: &ClickEvent, _, cx| {
                        if suppress {
                            cx.emit(SuppressEvent);
                        } else {
                            cx.emit(DismissEvent);
                        }
                    })),
            )
            .on_click(cx.listener(|this, _, window, cx| {
                this.focus_notification_panel(window, cx);
                cx.emit(DismissEvent);
            }))
    }
}

impl EventEmitter<DismissEvent> for NotificationToast {}
impl EventEmitter<SuppressEvent> for NotificationToast {}
