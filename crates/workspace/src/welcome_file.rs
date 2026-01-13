use crate::{item::{Item, ItemEvent}, Workspace};
use gpui::{
    App, Context, EventEmitter, FocusHandle, Focusable, FontWeight, ParentElement,
    Render, Styled, WeakEntity, Window, actions,
};
use ui::{prelude::*, Button, ButtonStyle, IconName, Label, LabelSize, Vector, VectorName};

actions!(
    witchcraft,
    [
        /// Show the Witchcraft welcome file when opening a new folder
        ShowWelcomeFile
    ]
);

pub struct WelcomeFile {
    workspace: WeakEntity<Workspace>,
    focus_handle: FocusHandle,
}

impl WelcomeFile {
    pub fn new(workspace: WeakEntity<Workspace>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let focus_handle = cx.focus_handle();
        cx.on_focus(&focus_handle, window, |_, _, cx| cx.notify())
            .detach();

        WelcomeFile {
            workspace,
            focus_handle,
        }
    }

    fn open_agent(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(workspace) = self.workspace.upgrade() {
            workspace.update(cx, |_, cx| {
                window.dispatch_action(Box::new(zed_actions::assistant::ToggleFocus), cx);
            });
        }
    }
}

impl Focusable for WelcomeFile {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl EventEmitter<ItemEvent> for WelcomeFile {}

impl Item for WelcomeFile {
    type Event = ItemEvent;

    fn tab_content_text(&self, _detail: usize, _cx: &App) -> SharedString {
        "Welcome to Witchcraft".into()
    }

    fn telemetry_event_text(&self) -> Option<&'static str> {
        Some("welcome file")
    }

    fn show_toolbar(&self) -> bool {
        false
    }

    fn to_item_events(event: &Self::Event, mut f: impl FnMut(crate::item::ItemEvent)) {
        f(*event)
    }
}

impl Render for WelcomeFile {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        v_flex()
            .size_full()
            .bg(cx.theme().colors().editor_background)
            .child(
                v_flex()
                    .items_center()
                    .justify_center()
                    .size_full()
                    .gap_8()
                    .child(
                        v_flex()
                            .items_center()
                            .gap_4()
                            .child(
                                Vector::square(VectorName::WitchcraftLogo, rems(3.0))
                                    .color(Color::Accent)
                            )
                            .child(
                                Label::new("Welcome to Witchcraft")
                                    .size(LabelSize::Large)
                                    .weight(FontWeight::BOLD)
                            )
                    )
                    .child(
                        v_flex()
                            .w(px(600.0))
                            .gap_6()
                            .child(
                                v_flex()
                                    .gap_3()
                                    .child(
                                        Label::new("Your AI-Powered Coding Assistant")
                                            .size(LabelSize::Default)
                                            .weight(FontWeight::SEMIBOLD)
                                            .color(Color::Accent)
                                    )
                                    .child(
                                        Label::new("Witchcraft helps you code smarter, not harder. Stop writing repetitive code and let AI assist you with:")
                                            .size(LabelSize::Default)
                                            .color(Color::Muted)
                                    )
                            )
                            .child(
                                v_flex()
                                    .gap_3()
                                    .child(self.render_feature("✨", "Understanding Your Project", "Get instant context about your codebase, architecture, and dependencies"))
                                    .child(self.render_feature("🐛", "Debugging Issues", "Identify and fix bugs faster with AI-powered analysis"))
                                    .child(self.render_feature("⚡", "Implementing Features", "Generate code, refactor existing code, and implement new features efficiently"))
                                    .child(self.render_feature("🎯", "Smart Suggestions", "Receive intelligent code completions and best practice recommendations"))
                            )
                            .child(
                                v_flex()
                                    .gap_3()
                                    .mt_4()
                                    .child(
                                        Label::new("Ready to start?")
                                            .size(LabelSize::Default)
                                            .weight(FontWeight::SEMIBOLD)
                                    )
                                    .child(
                                        Button::new("open-agent", "Open Witchcraft Agent")
                                            .style(ButtonStyle::Filled)
                                            .icon(IconName::Sparkle)
                                            .icon_position(IconPosition::Start)
                                            .label_size(LabelSize::Default)
                                            .on_click(cx.listener(|this, _, window, cx| {
                                                this.open_agent(window, cx);
                                            }))
                                    )
                            )
                            .child(
                                v_flex()
                                    .gap_2()
                                    .mt_6()
                                    .pt_6()
                                    .border_t_1()
                                    .border_color(cx.theme().colors().border)
                                    .child(
                                        Label::new("💡 Pro Tip")
                                            .size(LabelSize::Small)
                                            .weight(FontWeight::SEMIBOLD)
                                            .color(Color::Accent)
                                    )
                                    .child(
                                        Label::new("You can always access the agent with Cmd+/ (Mac) or Ctrl+/ (Windows/Linux)")
                                            .size(LabelSize::Small)
                                            .color(Color::Muted)
                                    )
                            )
                    )
            )
    }
}

impl WelcomeFile {
    fn render_feature(&self, icon: &'static str, title: &'static str, description: &'static str) -> impl IntoElement {
        h_flex()
            .gap_3()
            .child(
                div()
                    .flex_none()
                    .w(px(24.0))
                    .child(Label::new(icon).size(LabelSize::Default))
            )
            .child(
                v_flex()
                    .gap_1()
                    .child(
                        Label::new(title)
                            .size(LabelSize::Default)
                            .weight(FontWeight::SEMIBOLD)
                    )
                    .child(
                        Label::new(description)
                            .size(LabelSize::Small)
                            .color(Color::Muted)
                    )
            )
    }
}
