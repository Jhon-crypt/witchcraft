use crate::agent_panel::AgentPanel;
use gpui::{Action, App, Context, IntoElement, ParentElement, Render, Subscription, WeakEntity, Window};
use ui::{prelude::*, Button, ButtonStyle, IconName, IconPosition, LabelSize};
use workspace::{StatusItemView, Workspace};
use zed_actions::assistant::ToggleFocus;

pub struct WitchcraftAgentStatusItem {
    workspace: WeakEntity<Workspace>,
    _subscription: Option<Subscription>,
}

impl WitchcraftAgentStatusItem {
    pub fn new(workspace: WeakEntity<Workspace>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let subscription = workspace.upgrade().map(|workspace_entity| {
            cx.subscribe_in(&workspace_entity, window, |_this, _workspace, _event, _window, cx| {
                // Notify whenever workspace events occur to update button state
                cx.notify();
            })
        });
        
        Self { 
            workspace,
            _subscription: subscription,
        }
    }
}

impl Render for WitchcraftAgentStatusItem {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let is_panel_open = self
            .workspace
            .upgrade()
            .map(|workspace| !AgentPanel::is_hidden(&workspace, cx))
            .unwrap_or(false);

        let (label, icon) = if is_panel_open {
            ("Close Witchcraft Agent", IconName::Close)
        } else {
            ("Open Witchcraft Agent", IconName::Sparkle)
        };

        let workspace = self.workspace.clone();
        Button::new("toggle-witchcraft-agent-status", label)
            .icon(icon)
            .icon_position(IconPosition::Start)
            .style(ButtonStyle::Filled)
            .label_size(LabelSize::Small)
            .on_click(move |_, window, cx| {
                if let Some(workspace_entity) = workspace.upgrade() {
                    let is_open = !AgentPanel::is_hidden(&workspace_entity, cx);
                    workspace_entity.update(cx, |workspace, cx| {
                        if is_open {
                            workspace.close_panel::<AgentPanel>(window, cx);
                        } else {
                            workspace.open_panel::<AgentPanel>(window, cx);
                        }
                    });
                }
            })
    }
}

impl StatusItemView for WitchcraftAgentStatusItem {
    fn set_active_pane_item(
        &mut self,
        _active_pane_item: Option<&dyn workspace::ItemHandle>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // Notify to update the button text when the pane item changes
        cx.notify();
    }
}
