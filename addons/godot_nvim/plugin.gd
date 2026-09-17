@tool
extends EditorPlugin

## Puts Neovim on its own main-screen tab, next to 2D / 3D / Script.
##
## Nothing here touches Godot's internals: _has_main_screen() is public API,
## and the terminal itself is Godotty's Terminal node. If Godotty is missing
## the plugin degrades to a warning instead of breaking the editor.

const TAB_NAME := "Nvim"
const GODOTTY_CLASS := "Terminal"
## Must be on PATH (see README: home-manager snippet).
const LAUNCH_CMD := "godot-nvim-launch"

## Editor shortcuts we hand back to Godot while nvim owns the keyboard.
##
## Stored as shortcut *paths*, never as keycodes: editor/run/editor_run_bar.cpp:621,
## :666 and :647 register F5 / F6 / F8 and immediately override them for macOS
## (Cmd+B / Cmd+R / Cmd+.), and the user can rebind any of them in Editor
## Settings > Shortcuts. Matching the Shortcut resource gets all of that for free.
##
## Deliberately short. Ctrl+S is NOT here — nvim writes the buffer and Godot's
## auto_reload_scripts_on_external_change picks the file back up, which is the
## whole point of the setup.
const HANDBACK_SHORTCUTS := [
	"editor/run_project",          # F5 / Cmd+B
	"editor/run_current_scene",    # F6 / Cmd+R
	"editor/stop_running_project", # F8 / Cmd+.
]

## A terminal that dies faster than this counts as a launcher failure, not as a
## deliberate `:q`. Three of those in a row and we stop restarting it, so a
## broken godot-nvim-launch cannot turn tab-clicking into a crash loop.
const FAST_FAIL_MS := 3000
const FAST_FAIL_LIMIT := 3

var _term: Control = null
## Set from the `exited` signal, cleared when a fresh Terminal is attached.
var _dead := false
## Time.get_ticks_msec() at the moment the current Terminal entered the tree.
## Godotty spawns the PTY in Terminal::ready() (godotty terminal.rs:186-190),
## so entering the tree *is* the spawn.
var _spawned_at_ms := 0
var _fast_failures := 0


func _enter_tree() -> void:
	# _input() is auto-enabled at NOTIFICATION_READY for any script that overrides
	# it (node.cpp:255-258); saying so here is documentation, not a fix.
	set_process_input(true)
	_term = _make_terminal()
	if _term == null:
		push_warning("[godot-nvim] Godotty not found. Install it from AssetLib, " \
			+ "then re-enable this plugin.")
		return
	_term.hide()
	_attach(_term)


func _exit_tree() -> void:
	if is_instance_valid(_term):
		_term.queue_free()
	_term = null


## _input() is the ONLY hook that can preempt a focused Control.
##
## Viewport::push_input runs _input first (viewport.cpp:3537 — the engine's own
## comment there reads "must happen before GUI"), then _gui_input_event
## (viewport.cpp:3542), and only then _push_unhandled_input_internal
## (viewport.cpp:3549), which is where _shortcut_input (viewport.cpp:3622) and
## _unhandled_key_input live. Inside _gui_input_event a key event goes straight
## to the focus owner (viewport.cpp:2315) and the function returns the moment
## that control marks it handled (viewport.cpp:2318-2320).
##
## Godotty's Terminal overrides _gui_input (godotty terminal.rs:296) and ends
## handle_key() with accept_event() (terminal.rs:460) for every key it encodes —
## accept_event() is just Viewport::set_input_as_handled() (control.cpp:2543-2548,
## viewport.cpp:2746-2750). So _shortcut_input and _unhandled_key_input are dead
## ends here: by the time they would run, the event is already handled. That is
## exactly why F5 does nothing today.
##
## Godotty's own `godotty/terminal/passthrough_shortcuts` setting cannot do this
## job either: is_editor_passthrough() bails unless Ctrl / Alt / Meta is held
## (terminal.rs:1475-1477), and F5 / F6 / F8 carry no modifier. Its default value
## is only "Ctrl+Shift+P" (godotty plugin.rs:22-24), which is also why Ctrl+S
## reaches nvim untouched.
func _input(event: InputEvent) -> void:
	# Cheapest possible rejection first: _input sees every mouse motion too.
	var key := event as InputEventKey
	if key == null:
		return
	# Only preempt the terminal that would actually have eaten the key.
	# is_visible_in_tree() is not redundant with has_focus(): a hidden focus owner
	# keeps gui.key_focus until the *next* key event releases it
	# (viewport.cpp:2309-2311), and our _input runs before that cleanup.
	if not is_instance_valid(_term) or not _term.is_visible_in_tree() or not _term.has_focus():
		return

	var settings := EditorInterface.get_editor_settings()
	for path in HANDBACK_SHORTCUTS:
		# get_shortcut() rather than is_shortcut(): it returns a null ref for an
		# unknown path instead of warning (editor_settings.cpp:2111-2115), so this
		# degrades quietly if a shortcut is ever renamed upstream.
		var shortcut := settings.get_shortcut(path)
		if shortcut == null or not shortcut.matches_event(key):
			continue
		# Swallow press AND release. InputEventKey::is_match ignores `pressed`
		# (input_event.cpp:608-628), so the release matches too — and if we let it
		# through, Godotty would still encode it into the PTY.
		get_viewport().set_input_as_handled()
		if key.pressed and not key.echo:
			_run_handback(path)
		return


func _run_handback(path: String) -> void:
	match path:
		"editor/run_project":
			EditorInterface.play_main_scene()
		"editor/run_current_scene":
			EditorInterface.play_current_scene()
		"editor/stop_running_project":
			EditorInterface.stop_playing_scene()


func _make_terminal() -> Control:
	if not ClassDB.class_exists(GODOTTY_CLASS):
		return null
	var term := ClassDB.instantiate(GODOTTY_CLASS) as Control
	if term == null:
		return null
	# Godotty's `shell` is documented as "Command to run", so point it at the
	# launcher rather than nvim directly — the launcher owns the --listen socket
	# that godot-nvim-open talks back to. It resolves on PATH because exec_path
	# is a GLOBAL editor setting while addons are per-project: the scripts must
	# live in one place both can reach.
	term.set("shell", _launch_command())
	# -l would be passed to a login shell; nvim is not one and would reject it.
	term.set("login_shell", false)
	term.set("run_in_editor", true)
	term.set("working_directory", ProjectSettings.globalize_path("res://"))
	# get_editor_main_screen() is a VBoxContainer, and a container positions its
	# children itself — anchors are ignored there. Without EXPAND_FILL the
	# terminal collapses to its minimum size and never gets a usable grid.
	term.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	term.size_flags_vertical = Control.SIZE_EXPAND_FILL
	term.connect("exited", _on_nvim_exited)
	return term


## add_child() is what runs Terminal::ready(), which spawns the PTY, so the
## "spawned at" clock starts here and nowhere else.
func _attach(term: Control) -> void:
	EditorInterface.get_editor_main_screen().add_child(term)
	_dead = false
	_spawned_at_ms = Time.get_ticks_msec()


## Godotty has no restart API — its whole #[func] surface is is_exited() and
## on_editor_settings_changed() (terminal.rs:95-104), and `state` is only ever
## assigned in ready() (terminal.rs:186). So respawning means a new node.
##
## Lazily, on the next _make_visible(true), not immediately on `exited`:
##   - Terminal::ready() unconditionally grab_focus()es (terminal.rs:190). A
##     respawn while the Nvim tab is hidden would steal the keyboard from
##     whatever tab the user is actually in.
##   - `:q` is usually deliberate. Reopening nvim behind the user's back throws
##     away the exit they just asked for.
##   - It is inherently loop-free: a launcher that dies on startup can only be
##     retried as fast as a human re-selects the tab. The FAST_FAIL counter below
##     is belt-and-braces for the case where something re-selects it for us.
func _respawn() -> void:
	var host := EditorInterface.get_editor_main_screen()
	if is_instance_valid(_term):
		# remove_child before queue_free: the old node lives until the end of the
		# frame, and two EXPAND_FILL children would share the VBox for that frame.
		host.remove_child(_term)
		_term.queue_free()
	_term = _make_terminal()
	if _term == null:
		return
	# Visible *before* entering the tree, so ready()'s grab_focus() lands on a
	# control that is actually on screen.
	_term.visible = true
	_attach(_term)


func _on_nvim_exited(code: int) -> void:
	_dead = true
	if Time.get_ticks_msec() - _spawned_at_ms < FAST_FAIL_MS:
		_fast_failures += 1
	else:
		# A session that lived a while was a real session; forget old failures.
		_fast_failures = 0
	if _fast_failures >= FAST_FAIL_LIMIT:
		push_warning("[godot-nvim] nvim exited (code %d) within %dms, %d times in a row. " \
			% [code, FAST_FAIL_MS, _fast_failures] \
			+ "Not restarting it again — check that '%s' works from a shell, " % _launch_command() \
			+ "then disable and re-enable the plugin.")
		return
	push_warning("[godot-nvim] nvim exited (code %d). Re-select the Nvim tab to restart it." % code)


func _launch_command() -> String:
	# The launcher ships inside the addon, so an installed plugin is self-contained
	# and needs nothing on PATH. The PATH fallback stays for anyone who would rather
	# install the scripts system-wide.
	var bundled := ProjectSettings.globalize_path(
		"res://addons/godot_nvim/bin/godot-nvim-launch")
	if FileAccess.file_exists(bundled):
		return bundled
	return LAUNCH_CMD


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return TAB_NAME


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon(&"Script", &"EditorIcons")


## EditorMainScreen::select() calls make_visible(false) on the outgoing plugin and
## make_visible(true) on the incoming one (editor_main_screen.cpp:193-197) and
## touches nothing else in the VBox, so this method is the sole owner of the
## terminal's visibility — and the natural place to rebuild a dead one.
func _make_visible(visible: bool) -> void:
	if visible and _dead and _fast_failures < FAST_FAIL_LIMIT:
		_respawn()
	if not is_instance_valid(_term):
		return
	_term.visible = visible
	if visible:
		_term.grab_focus()
	else:
		# Drop focus on the way out so the stale-focus-owner window in _input()
		# never opens, and so nvim gets its FocusLost (godotty reports CSI focus
		# on FOCUS_EXIT, terminal.rs:321-327).
		_term.release_focus()
