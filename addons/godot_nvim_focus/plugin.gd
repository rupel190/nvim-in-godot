@tool
extends EditorPlugin

## Companion to godot_nvim. Exists ONLY to notice that a Script was opened and
## bring the Nvim workspace forward.
##
## WHY A SECOND PLUGIN instead of _handles() on the main-screen one:
## EditorNode has two dispatch pools, and only one of them is winner-take-all.
##   get_handling_main_editor()  (editor_data.cpp:260) returns exactly ONE plugin
##     and iterates BACKWARDS so user addons outrank built-ins. Putting _handles()
##     on our main-screen plugin would displace ScriptEditorPlugin, so
##     ScriptEditor::edit() would never run and nvim would never be launched.
##   get_handling_sub_editors() (editor_data.cpp:272) is ADDITIVE and collects
##     only plugins with `!has_main_screen()`. We land here, coexisting with
##     ScriptEditorPlugin, and are called from editor_node.cpp:3316 — which runs
##     AFTER the external editor was already spawned at :3298.

const MAIN_SCREEN_NAME := "Nvim"
const MAIN_PLUGIN := "godot_nvim"


func _has_main_screen() -> bool:
	# ⛔ Must stay false. True here steals ScriptEditorPlugin's dispatch.
	return false


func _handles(object: Object) -> bool:
	return object is Script


func _edit(object: Object) -> void:
	if object == null:
		return  # deselection
	var settings := EditorInterface.get_editor_settings()
	if not bool(settings.get_setting("text_editor/external/use_external_editor")):
		return  # internal editor in use — let Godot switch to its own Script tab
	# Deferred because we are currently inside EditorNode::_edit_current() ->
	# edit_item(), and set_main_screen_editor() re-enters make_visible() on
	# plugins while that list is being iterated.
	_focus_nvim.call_deferred()


func _focus_nvim() -> void:
	# Without the Nvim tab, set_main_screen_editor() fails on an unknown name
	# (editor_main_screen.cpp:167). Self-guarding lets us stay enabled across
	# sessions instead of being toggled on and off by the main plugin.
	if not EditorInterface.is_plugin_enabled(MAIN_PLUGIN):
		return
	EditorInterface.set_main_screen_editor(MAIN_SCREEN_NAME)
