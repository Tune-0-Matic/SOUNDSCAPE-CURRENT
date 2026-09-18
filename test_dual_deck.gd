extends SceneTree
## Runnable check for DUAL DECK MODE and DUAL VISUAL:
##   1. a deck tracker's analyser switches on for DUAL VISUAL alone, with no tempo fit, and
##      off again only when neither SYNC nor DUAL VISUAL wants it
##   2. player.tscn carries what player.gd reaches for: deck A's wing (%DeckAPanel holding the
##      %DeckADock TabContainer) hidden left of %Workspace behind the %Body divider, and a second
##      Visualizer (%VizB) under %VizBox in %VizStack, hidden,
##      not rendering, on the same CRT material
##   3. losing application focus caps the frame rate at 30 (never above a lower user cap), and
##      focus returning restores the user's cap, uncapped included
##   4. player.gd's sleep_hidden_pages: a tab page processes only while it is visible in the
##      tree -- through a tab click, a tear-off, re-docking and its dock hiding -- and keeps its state
## Builds its own bus and never boots player.tscn (no _ready), so user:// is never touched.
##   godot --headless --path . --script res://test_dual_deck.gd

func _initialize() -> void:
	var ok := true

	AudioServer.add_bus()
	var bus := AudioServer.bus_count - 1
	AudioServer.set_bus_name(bus, "DualDeckTest")
	var tracker := AudioDirector.new()
	tracker.bus = "DualDeckTest"
	root.add_child(tracker)
	tracker._bind_analyser()   # _ready would, a frame from now
	var slot := AudioServer.get_bus_effect_count(bus) - 1
	var states := []
	for args in [[false, true], [true, true], [false, false]]:
		tracker.set_tracking(args[0], args[1])
		states.append([tracker.track_tempo, AudioServer.is_bus_effect_enabled(bus, slot)])
	var analyse: bool = states == [[false, true], [true, true], [false, false]]
	ok = ok and analyse
	print("analyser on without a tempo fit, both on, both off: %s %s" % [analyse, states])
	tracker.free()
	AudioServer.remove_bus(bus)

	var scene: Control = load("res://player.tscn").instantiate()   # never enters the tree: no _ready
	# a player.gd that fails to parse still instantiates the scene, just with no script on the root
	var compiled: bool = scene.has_method("_set_dual_deck")
	ok = ok and compiled
	print("player.gd compiled onto the scene root: %s" % compiled)
	var wing: Control = scene.get_node("%DeckAPanel")
	var work: Control = scene.get_node("%Workspace")
	var row: bool = not wing.visible and wing.get_parent() == scene.get_node("%Body") \
		and scene.get_node("%Body") is SplitContainer and wing.get_index() == 0 and work.get_index() == 1 \
		and scene.get_node("%DeckADock") is TabContainer and scene.get_node("%DeckADock").get_parent() == wing
	var box_a: SubViewportContainer = scene.get_node("%VizBox")
	var box_b: SubViewportContainer = scene.get_node("%VizBoxB")
	var viz_b: Node = scene.get_node("%VizB")
	var stack: bool = box_a.get_parent() == scene.get_node("%VizStack") and box_b.get_parent() == box_a.get_parent() \
		and box_b.get_index() == box_a.get_index() + 1 and not box_b.visible and viz_b is Visualizer \
		and (box_b.get_child(0) as SubViewport).render_target_update_mode == SubViewport.UPDATE_DISABLED \
		and box_b.material == box_a.material and box_b.stretch_shrink == box_a.stretch_shrink
	var list_a: Node = scene.get_node_or_null("%TracksA")
	var list_b: Node = scene.get_node_or_null("%TracksB")
	var lists: bool = list_a is ItemList and list_b is ItemList and list_a.get_parent() != list_b.get_parent() \
		and list_a.get_parent().get_parent() == scene.get_node("%Tabs") and list_b.get_parent().get_parent() == scene.get_node("%Tabs")
	# TRK B's header matches TRK A's: search, then the sort + playlist row, above the list
	for pair in [["%Search", "%Sort", "%Playlist", list_a], ["%SearchB", "%SortB", "%PlaylistB", list_b]]:
		var search: Node = scene.get_node_or_null(pair[0])
		var sort: Node = scene.get_node_or_null(pair[1])
		var picker: Node = scene.get_node_or_null(pair[2])
		var tab: Node = (pair[3] as Node).get_parent()
		lists = lists and search is LineEdit and sort is Button and picker is OptionButton \
			and search.get_parent() == tab and sort.get_parent().get_parent() == tab and picker.get_parent() == sort.get_parent() \
			and search.get_index() < sort.get_parent().get_index() and sort.get_parent().get_index() < (pair[3] as Node).get_index()
	print("two track lists, %%TracksA and %%TracksB, each its own tab under the same search / sort / playlist header: %s" % lists)
	ok = ok and row and stack and lists
	print("deck A wing left of the workspace behind its own divider: %s; deck B visualizer stacked under A, hidden, same CRT: %s" % [
		row, stack])

	# 3. the background frame cap: 30 while another program has focus, never raising a lower
	# user cap, and the user's own cap back on return
	var fps_was := Engine.max_fps
	var caps := []
	for user_cap in [60, 0, 24, 144]:
		scene.set("_max_fps", user_cap)
		scene.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
		var away := Engine.max_fps
		scene.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
		caps.append([away, Engine.max_fps])
	Engine.max_fps = fps_was
	var throttle: bool = caps == [[30, 60], [30, 0], [24, 24], [30, 144]]
	ok = ok and throttle
	print("unfocused cap for user caps 60 / uncapped / 24 / 144, then restored [away, back]: %s: %s" % [caps, throttle])
	scene.free()

	# 4. off-screen tab pages sleep, and wake with their state, however they got there
	var dock := TabContainer.new()
	root.add_child(dock)
	var pages: Array[Control] = []
	for i in 3:
		var page := VBoxContainer.new()
		var field := LineEdit.new()
		field.text = "page %d" % i
		page.add_child(field)
		dock.add_child(page)
		pages.append(page)
	load("res://player.gd").sleep_hidden_pages(dock)
	await process_frame   # nothing is visible in the tree until the root window's first frame
	var consistent := func() -> bool:
		return pages.all(func(p: Control) -> bool:
			return p.process_mode == (Node.PROCESS_MODE_INHERIT if p.is_visible_in_tree() else Node.PROCESS_MODE_DISABLED))
	var steps := []
	steps.append(consistent.call() and pages[0].can_process() and not pages[1].can_process() and not pages[2].can_process())
	dock.current_tab = 2   # a tab click
	steps.append(consistent.call() and pages[2].can_process() and not pages[0].can_process())
	var window := VBoxContainer.new()   # a torn-off window's column
	root.add_child(window)
	pages[0].reparent(window, false)
	pages[0].show()
	steps.append(consistent.call() and pages[0].can_process())
	pages[0].reparent(dock, false)   # docked again, behind the current tab
	steps.append(consistent.call() and not pages[0].can_process() and pages[2].can_process())
	dock.hide()   # the whole dock folded away
	steps.append(consistent.call() and not pages[2].can_process())
	dock.show()
	dock.current_tab = dock.get_tab_idx_from_control(pages[0])
	steps.append(consistent.call() and pages[0].can_process() and not pages[2].can_process())
	var kept := pages.all(func(p: Control) -> bool: return (p.get_child(0) as LineEdit).text == "page %d" % pages.find(p))
	var sleeps: bool = not steps.has(false) and kept
	ok = ok and sleeps
	print("tab pages asleep only while unseen -- boot, click, torn off, re-docked, dock hidden, dock shown: %s; text kept %s: %s" % [
		steps, kept, sleeps])
	dock.free()
	window.free()

	# player.gd asserts its pure rules at boot, and nothing in the suite boots player.tscn, so the
	# ones that would otherwise never run are run here: cue times mirroring while a deck is
	# reversed, what an unplayable track does depending on who asked for it, and the equal-power
	# crossfader law. They moved to DeckController and AudioEngine when player.gd was split up.
	var rules: bool = DeckController.deck_test() and AudioEngine.deck_test() and LibraryModel.model_test() 		and load("res://player.gd").settings_test()
	ok = ok and rules
	print("deck rules (REV cue mirroring, auto-advance faults), the equal-power crossfader and the library model: %s" % rules)

	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
