use crate::zed::auth_manager::{AuthEvent, AuthManager};
use gpui::{
    App, Context, DismissEvent, Entity, EventEmitter, FocusHandle, Focusable, Render, SharedString,
    Subscription, Window,
};
use ui::{AlertModal, prelude::*, Button, ButtonStyle, Label, LabelSize};
use ui_input::InputField;
use workspace::{ModalView, Workspace};

/// Modal that prompts the user for the Witchcraft access code and sends it to the auth manager.
pub struct WitchcraftAccessCodeModal {
    focus_handle: FocusHandle,
    access_code_input: Entity<InputField>,
    error: Option<SharedString>,
    is_submitting: bool,
    _auth_subscription: Option<Subscription>,
}

impl WitchcraftAccessCodeModal {
    pub fn toggle(
        workspace: &mut Workspace,
        window: &mut Window,
        cx: &mut Context<Workspace>,
    ) {
        log::info!("Opening Witchcraft access code modal");
        workspace.toggle_modal(window, cx, |window, cx| Self::new(window, cx));
    }

    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        log::info!("Building Witchcraft access code modal view");
        let input = cx.new(|cx| {
            InputField::new(window, cx, "Paste access code from browser…")
                .label("Access code")
        });

        let auth_subscription = AuthManager::global_entity(cx).map(|manager| {
            cx.subscribe_in(&manager, window, |this, _auth, event, _window, cx| match event {
                AuthEvent::SignedIn => {
                    this.is_submitting = false;
                    cx.emit(DismissEvent);
                }
                AuthEvent::SignedOut => {
                    this.is_submitting = false;
                    cx.notify();
                }
                AuthEvent::AuthError(message) => {
                    this.is_submitting = false;
                    this.error = Some(message.into());
                    cx.notify();
                }
            })
        });

        Self {
            focus_handle: cx.focus_handle(),
            access_code_input: input,
            error: None,
            is_submitting: false,
            _auth_subscription: auth_subscription,
        }
    }

    fn submit(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        let code = self
            .access_code_input
            .read(cx)
            .text(cx)
            .trim()
            .to_string();

        if code.is_empty() {
            self.error = Some("Access code cannot be empty".into());
            cx.notify();
            return;
        }

        self.error = None;
        self.is_submitting = true;
        cx.notify();

        AuthManager::sign_in_with_access_code_global(code, cx);
    }

    fn cancel(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        cx.emit(DismissEvent);
    } 
}

impl EventEmitter<DismissEvent> for WitchcraftAccessCodeModal {}

impl Focusable for WitchcraftAccessCodeModal {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl ModalView for WitchcraftAccessCodeModal {}

impl Render for WitchcraftAccessCodeModal {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let input = self.access_code_input.clone();

        let mut modal = AlertModal::new("witchcraft-access-code-modal")
            .title("Enter your access code")
            .width(rems(28.0))
            .child(
                Label::new(
                    "After signing in with GitHub, paste the access code here to link Witchcraft.",
                )
                .size(LabelSize::Small)
                .color(Color::Muted),
            )
            .child(div().child(input));

        if self.is_submitting {
            modal = modal.child(
                v_flex()
                    .mt_2()
                    .child(
                        Label::new("Syncing your Witchcraft account…")
                            .size(LabelSize::Small)
                            .color(Color::Muted),
                    ),
            );
        }

        if let Some(error) = self.error.clone() {
            modal = modal.child(
                v_flex()
                    .mt_2()
                    .child(
                        Label::new(error)
                            .size(LabelSize::Small)
                            .color(Color::Error),
                    ),
            );
        }

        modal.footer(
            h_flex()
                .p_3()
                .items_center()
                .justify_end()
                .gap_1()
                .child(
                    Button::new("cancel-access-code", "Cancel")
                        .style(ButtonStyle::Subtle)
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.cancel(window, cx);
                        })),
                )
                .child(
                    Button::new("continue-access-code", "Continue")
                        .style(ButtonStyle::Filled)
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.submit(window, cx);
                        })),
                ),
        )
    }
}

