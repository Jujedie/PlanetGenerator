class_name ReferenceViewerWorkspace
extends CanvasLayer

var UI_AMBER: Color:
	get: return UITheme.color(&"accent")
var UI_AMBER_BRIGHT: Color:
	get: return UITheme.color(&"accent_bright")
var UI_DARK: Color:
	get: return UITheme.color(&"background")
var UI_PANEL: Color:
	get: return UITheme.color(&"panel")
var UI_PANEL_ALT: Color:
	get: return UITheme.color(&"panel_alt")
var UI_BORDER: Color:
	get: return UITheme.color(&"border")
var UI_TEXT: Color:
	get: return UITheme.color(&"text")
var UI_TEXT_BRIGHT: Color:
	get: return UITheme.color(&"text_bright")
var UI_MUTED: Color:
	get: return UITheme.color(&"muted")

var root: Control
var header_panel: PanelContainer
var phase_label: Label
var memory_label: Label
var status_dot: Label
var progress_bar: ProgressBar
var parameters_button: Button
var cancel_button: Button
var theme_select: OptionButton
var map_viewport: PanelContainer
var map_canvas: Control
var map_texture: TextureRect
var overlay_texture: TextureRect
var crosshair: PlanetMapCrosshair
var empty_label: Label
var load_button: Button
var save_button: Button
var viewer_panel: PanelContainer
var viewer_title_label: Label
var shortcut_label: Label
var base_title_label: Label
var base_select: OptionButton
var overlay_title_label: Label
var overlay_select: OptionButton
var opacity_title_label: Label
var opacity_slider: HSlider
var opacity_percent_label: Label
var zoom_label: Label
var reset_button: Button
var inspector_label: Label
var help_label: Label


func _ready() -> void:
	layer = 40
	_build_interface()
	UITheme.apply_to_tree(root)
	if not UITheme.theme_changed.is_connected(_on_theme_changed):
		UITheme.theme_changed.connect(_on_theme_changed)
	get_viewport().size_changed.connect(_layout_interface)
	_layout_interface()


func _panel_style(
	background: Color = Color(0.065, 0.078, 0.082, 0.98),
	border: Color = Color(0.19, 0.23, 0.24, 1.0),
	border_width: int = 1,
	content_margin: float = 10.0
) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(border_width)
	style.content_margin_left = content_margin
	style.content_margin_top = content_margin
	style.content_margin_right = content_margin
	style.content_margin_bottom = content_margin
	return style


func style_button(button: Button, compact: bool = false) -> void:
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(118 if compact else 170, 34 if compact else 40)
	button.add_theme_color_override("font_color", UI_AMBER)
	button.add_theme_color_override("font_hover_color", UI_DARK)
	button.add_theme_color_override("font_pressed_color", UI_DARK)
	button.add_theme_color_override("font_disabled_color", UI_MUTED)
	button.add_theme_font_size_override("font_size", 18 if compact else 21)
	button.add_theme_stylebox_override("normal", _panel_style(Color(0.04, 0.05, 0.055, 1.0), UI_AMBER, 2, 4.0))
	button.add_theme_stylebox_override("hover", _panel_style(UI_AMBER_BRIGHT, UI_AMBER_BRIGHT, 2, 4.0))
	button.add_theme_stylebox_override("pressed", _panel_style(UI_AMBER, UI_AMBER, 2, 4.0))
	button.add_theme_stylebox_override("disabled", _panel_style(Color(0.05, 0.06, 0.065, 1.0), UI_BORDER, 1, 4.0))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _style_option(option: OptionButton) -> void:
	option.focus_mode = Control.FOCUS_NONE
	option.custom_minimum_size = Vector2(360, 44)
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.add_theme_color_override("font_color", UI_TEXT_BRIGHT)
	option.add_theme_color_override("font_hover_color", UI_AMBER_BRIGHT)
	option.add_theme_color_override("font_pressed_color", UI_AMBER_BRIGHT)
	option.add_theme_font_size_override("font_size", 21)
	var field_style := _panel_style(Color(0.035, 0.045, 0.05, 1.0), UI_BORDER, 1, 9.0)
	for style_name in ["normal", "normal_mirrored", "pressed", "pressed_mirrored", "hover", "hover_mirrored", "hover_pressed", "hover_pressed_mirrored", "disabled", "disabled_mirrored"]:
		option.add_theme_stylebox_override(style_name, field_style)
	option.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_style_popup_menu(option.get_popup(), 600)


func _style_popup_menu(popup: PopupMenu, minimum_width: int) -> void:
	popup.min_size = Vector2i(minimum_width, 0)
	popup.max_size = Vector2i(760, 620)
	popup.add_theme_font_size_override("font_size", 21)
	popup.add_theme_color_override("font_color", UI_TEXT_BRIGHT)
	popup.add_theme_color_override("font_hover_color", UI_DARK)
	popup.add_theme_color_override("font_pressed_color", UI_DARK)
	popup.add_theme_color_override("font_checked_color", UI_AMBER_BRIGHT)
	popup.add_theme_color_override("font_disabled_color", UI_MUTED)
	popup.add_theme_color_override("font_separator_color", UI_AMBER)
	popup.add_theme_constant_override("v_separation", 8)
	popup.add_theme_constant_override("h_separation", 12)
	popup.add_theme_constant_override("item_start_padding", 14)
	popup.add_theme_constant_override("item_end_padding", 14)
	popup.add_theme_stylebox_override("panel", _panel_style(Color(0.035, 0.045, 0.05, 0.99), UI_AMBER, 2, 8.0))
	popup.add_theme_stylebox_override("hover", _panel_style(UI_AMBER_BRIGHT, UI_AMBER_BRIGHT, 0, 5.0))
	var unchecked_icon := load("res://data/img/UI/Range/Grabber.png") as Texture2D
	var checked_icon := load("res://data/img/UI/Range/Grabber_grabbed.png") as Texture2D
	popup.add_theme_icon_override("radio_unchecked", unchecked_icon)
	popup.add_theme_icon_override("radio_checked", checked_icon)
	popup.add_theme_icon_override("unchecked", unchecked_icon)
	popup.add_theme_icon_override("checked", checked_icon)
	_style_popup_scrollbars(popup)


func _style_popup_scrollbars(popup: PopupMenu) -> void:
	for node in popup.find_children("*", "VScrollBar", true, false):
		var scrollbar := node as VScrollBar
		scrollbar.custom_minimum_size.x = 16
		scrollbar.add_theme_stylebox_override("scroll", _panel_style(Color(0.055, 0.065, 0.07, 1.0), UI_BORDER, 1, 4.0))
		scrollbar.add_theme_stylebox_override("grabber", _panel_style(UI_AMBER, UI_AMBER, 0, 4.0))
		scrollbar.add_theme_stylebox_override("grabber_highlight", _panel_style(UI_AMBER_BRIGHT, UI_AMBER_BRIGHT, 0, 4.0))
		scrollbar.add_theme_stylebox_override("grabber_pressed", _panel_style(UI_AMBER_BRIGHT, UI_AMBER_BRIGHT, 0, 4.0))


func _make_group(parent: Container, min_width: float) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = min_width
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _panel_style(UI_PANEL_ALT, UI_BORDER, 1, 8.0))
	parent.add_child(panel)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	panel.add_child(content)
	var title := Label.new()
	title.add_theme_color_override("font_color", UI_AMBER)
	title.add_theme_font_size_override("font_size", 18)
	content.add_child(title)
	return content


func _build_interface() -> void:
	root = Control.new()
	root.name = "ReferenceViewer"
	root.theme = UITheme.create_theme()
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var background := ColorRect.new()
	background.name = "Background"
	background.color = UI_DARK
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	header_panel = PanelContainer.new()
	header_panel.name = "GenerationStatus"
	header_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.045, 0.055, 0.06, 1.0), UI_BORDER, 2, 12.0))
	root.add_child(header_panel)
	var header_box := VBoxContainer.new()
	header_box.add_theme_constant_override("separation", 6)
	header_panel.add_child(header_box)
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 10)
	header_box.add_child(header_row)
	status_dot = Label.new()
	status_dot.name = "StatusDot"
	status_dot.text = "●"
	status_dot.add_theme_color_override("font_color", UI_MUTED)
	status_dot.add_theme_font_size_override("font_size", 20)
	header_row.add_child(status_dot)
	phase_label = Label.new()
	phase_label.name = "PhaseLabel"
	phase_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	phase_label.add_theme_color_override("font_color", UI_AMBER)
	phase_label.add_theme_font_size_override("font_size", 22)
	header_row.add_child(phase_label)
	memory_label = Label.new()
	memory_label.name = "TimingLabel"
	memory_label.custom_minimum_size.x = 360
	memory_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	memory_label.add_theme_color_override("font_color", UI_TEXT)
	memory_label.add_theme_font_size_override("font_size", 20)
	header_row.add_child(memory_label)
	parameters_button = Button.new()
	parameters_button.name = "ParametersButton"
	style_button(parameters_button, true)
	header_row.add_child(parameters_button)
	theme_select = OptionButton.new()
	theme_select.name = "ThemeSelect"
	_style_option(theme_select)
	theme_select.custom_minimum_size = Vector2(165, 38)
	theme_select.get_popup().min_size = Vector2i(260, 0)
	theme_select.get_popup().max_size = Vector2i(360, 360)
	_populate_theme_selector()
	theme_select.item_selected.connect(_on_theme_selected)
	header_row.add_child(theme_select)
	cancel_button = Button.new()
	cancel_button.name = "CancelButton"
	style_button(cancel_button, true)
	cancel_button.disabled = true
	header_row.add_child(cancel_button)
	progress_bar = ProgressBar.new()
	progress_bar.name = "Progress"
	progress_bar.custom_minimum_size.y = 18
	progress_bar.min_value = 0.0
	progress_bar.max_value = 100.0
	progress_bar.show_percentage = true
	progress_bar.add_theme_color_override("font_color", UI_DARK)
	progress_bar.add_theme_font_size_override("font_size", 16)
	progress_bar.add_theme_stylebox_override("background", _panel_style(Color(0.11, 0.13, 0.14, 1.0), UI_BORDER, 1, 0.0))
	progress_bar.add_theme_stylebox_override("fill", _panel_style(UI_AMBER, UI_AMBER, 0, 0.0))
	header_box.add_child(progress_bar)

	map_viewport = PanelContainer.new()
	map_viewport.name = "MapViewport"
	map_viewport.clip_contents = true
	map_viewport.mouse_filter = Control.MOUSE_FILTER_STOP
	map_viewport.add_theme_stylebox_override("panel", _panel_style(Color(0.018, 0.023, 0.025, 1.0), UI_BORDER, 2, 2.0))
	root.add_child(map_viewport)
	map_canvas = Control.new()
	map_canvas.name = "MapCanvas"
	map_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_viewport.add_child(map_canvas)
	map_texture = TextureRect.new()
	map_texture.name = "Map"
	map_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	map_texture.stretch_mode = TextureRect.STRETCH_SCALE
	map_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_canvas.add_child(map_texture)
	map_texture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay_texture = TextureRect.new()
	overlay_texture.name = "MapOverlay"
	overlay_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	overlay_texture.stretch_mode = TextureRect.STRETCH_SCALE
	overlay_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay_texture.modulate.a = 0.65
	map_canvas.add_child(overlay_texture)
	overlay_texture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	crosshair = PlanetMapCrosshair.new()
	crosshair.name = "MapCrosshair"
	map_canvas.add_child(crosshair)
	empty_label = Label.new()
	empty_label.name = "EmptyState"
	empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	empty_label.add_theme_color_override("font_color", UI_MUTED)
	empty_label.add_theme_font_size_override("font_size", 28)
	empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_viewport.add_child(empty_label)

	var action_panel := PanelContainer.new()
	action_panel.name = "MapActions"
	action_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.045, 0.055, 0.06, 1.0), UI_BORDER, 1, 8.0))
	root.add_child(action_panel)
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 10)
	action_panel.add_child(action_row)
	load_button = Button.new()
	load_button.name = "LoadPlanetButton"
	style_button(load_button)
	action_row.add_child(load_button)
	var left_spacer := Control.new()
	left_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_row.add_child(left_spacer)
	var brand := Label.new()
	brand.text = "JUJEDIE INC."
	brand.add_theme_color_override("font_color", Color(0.18, 0.2, 0.21, 1.0))
	brand.add_theme_font_size_override("font_size", 30)
	brand.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	action_row.add_child(brand)
	var right_spacer := Control.new()
	right_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_row.add_child(right_spacer)
	save_button = Button.new()
	save_button.name = "SavePlanetButton"
	style_button(save_button)
	action_row.add_child(save_button)

	viewer_panel = PanelContainer.new()
	viewer_panel.name = "MapViewerControls"
	viewer_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.045, 0.055, 0.06, 1.0), UI_BORDER, 2, 10.0))
	root.add_child(viewer_panel)
	var viewer_box := VBoxContainer.new()
	viewer_box.add_theme_constant_override("separation", 7)
	viewer_panel.add_child(viewer_box)
	viewer_title_label = Label.new()
	viewer_title_label.name = "ViewerTitle"
	viewer_title_label.add_theme_color_override("font_color", UI_AMBER)
	viewer_title_label.add_theme_font_size_override("font_size", 21)
	viewer_box.add_child(viewer_title_label)
	shortcut_label = Label.new()
	shortcut_label.name = "ShortcutLabel"
	shortcut_label.add_theme_color_override("font_color", UI_AMBER)
	shortcut_label.add_theme_font_size_override("font_size", 16)
	shortcut_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	viewer_box.add_child(shortcut_label)
	# Map selectors get a dedicated full-width row. The exported map catalogue
	# can contain dozens of layers/resources, so keeping them in narrow 290 px
	# columns made the PopupMenu unnecessarily difficult to use.
	var selectors_row := HFlowContainer.new()
	selectors_row.add_theme_constant_override("separation", 10)
	viewer_box.add_child(selectors_row)
	var base_group := _make_group(selectors_row, 520)
	base_title_label = base_group.get_child(0) as Label
	base_select = OptionButton.new()
	base_select.name = "BaseSelect"
	_style_option(base_select)
	base_group.add_child(base_select)
	var overlay_group := _make_group(selectors_row, 520)
	overlay_title_label = overlay_group.get_child(0) as Label
	overlay_select = OptionButton.new()
	overlay_select.name = "OverlaySelect"
	_style_option(overlay_select)
	overlay_group.add_child(overlay_select)

	var tools_row := HFlowContainer.new()
	tools_row.add_theme_constant_override("separation", 10)
	viewer_box.add_child(tools_row)
	var opacity_group := _make_group(tools_row, 620)
	opacity_title_label = opacity_group.get_child(0) as Label
	var opacity_row := HBoxContainer.new()
	opacity_row.add_theme_constant_override("separation", 8)
	opacity_group.add_child(opacity_row)
	opacity_slider = HSlider.new()
	opacity_slider.name = "OverlayOpacity"
	opacity_slider.max_value = 1.0
	opacity_slider.step = 0.05
	opacity_slider.value = 0.65
	opacity_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opacity_slider.custom_minimum_size = Vector2(360, 24)
	opacity_slider.add_theme_icon_override("grabber", load("res://data/img/UI/Range/Grabber.png"))
	opacity_slider.add_theme_icon_override("grabber_highlight", load("res://data/img/UI/Range/Grabber_grabbed.png"))
	opacity_slider.add_theme_stylebox_override("slider", load("res://data/styles/slider_non_highlight.tres"))
	opacity_slider.add_theme_stylebox_override("grabber_area", load("res://data/styles/slider_highlight.tres"))
	opacity_row.add_child(opacity_slider)
	opacity_percent_label = Label.new()
	opacity_percent_label.custom_minimum_size.x = 52
	opacity_percent_label.text = "65%"
	opacity_percent_label.add_theme_color_override("font_color", UI_TEXT)
	opacity_percent_label.add_theme_font_size_override("font_size", 18)
	opacity_row.add_child(opacity_percent_label)
	var zoom_group := _make_group(tools_row, 360)
	(zoom_group.get_child(0) as Label).text = "ZOOM"
	var zoom_row := HBoxContainer.new()
	zoom_row.add_theme_constant_override("separation", 8)
	zoom_group.add_child(zoom_row)
	zoom_label = Label.new()
	zoom_label.name = "ZoomLabel"
	zoom_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zoom_label.add_theme_color_override("font_color", UI_AMBER)
	zoom_label.add_theme_font_size_override("font_size", 18)
	zoom_row.add_child(zoom_label)
	reset_button = Button.new()
	reset_button.name = "ResetButton"
	style_button(reset_button, true)
	zoom_row.add_child(reset_button)

	var inspector_panel := PanelContainer.new()
	inspector_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector_panel.add_theme_stylebox_override("panel", _panel_style(UI_PANEL_ALT, UI_BORDER, 1, 7.0))
	viewer_box.add_child(inspector_panel)
	inspector_label = Label.new()
	inspector_label.name = "InspectorLabel"
	inspector_label.custom_minimum_size.y = 40
	inspector_label.add_theme_color_override("font_color", UI_TEXT)
	inspector_label.add_theme_font_size_override("font_size", 18)
	inspector_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inspector_panel.add_child(inspector_label)
	help_label = Label.new()
	help_label.add_theme_color_override("font_color", UI_MUTED)
	help_label.add_theme_color_override("font_color", Color(0.58, 0.62, 0.63, 1.0))
	help_label.add_theme_font_size_override("font_size", 16)
	viewer_box.add_child(help_label)


func _populate_theme_selector() -> void:
	theme_select.clear()
	for theme_id in UITheme.get_theme_ids():
		theme_select.add_item(UITheme.get_theme_name(theme_id))
		theme_select.set_item_metadata(theme_select.item_count - 1, theme_id)
	theme_select.select(UITheme.get_theme_index())
	theme_select.tooltip_text = tr("UI_THEME_TOOLTIP")


func refresh_translations() -> void:
	if theme_select != null:
		_populate_theme_selector()
	call_deferred("_layout_interface")


func _on_theme_selected(index: int) -> void:
	if index < 0 or index >= theme_select.item_count:
		return
	UITheme.set_theme(StringName(theme_select.get_item_metadata(index)))


func _on_theme_changed(_theme_id: StringName) -> void:
	UITheme.apply_to_tree(root)
	theme_select.select(UITheme.get_theme_index())
	# High-contrast mode changes font metrics; refresh geometry after the new
	# minimum sizes are known instead of leaving controls outside their panels.
	call_deferred("_layout_interface")


func _layout_interface() -> void:
	if root == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var margin := 22.0
	var header_height := 88.0
	var narrow_layout: bool = viewport_size.x < 1180.0
	var viewer_height := clampf(viewport_size.y * (0.48 if narrow_layout else 0.36), 440.0 if narrow_layout else 315.0, 520.0 if narrow_layout else 370.0)
	var viewer_top := viewport_size.y - viewer_height - margin
	var action_height := 52.0
	var action_top := viewer_top - action_height - 10.0
	var map_top := margin + header_height + 14.0
	var map_bottom := action_top - 10.0
	header_panel.position = Vector2(margin, margin)
	header_panel.size = Vector2(viewport_size.x - margin * 2.0, header_height)
	map_viewport.position = Vector2(margin, map_top)
	map_viewport.size = Vector2(viewport_size.x - margin * 2.0, maxf(map_bottom - map_top, 180.0))
	var actions := root.get_node("MapActions") as Control
	actions.position = Vector2(margin, action_top)
	actions.size = Vector2(viewport_size.x - margin * 2.0, action_height)
	viewer_panel.position = Vector2(margin, viewer_top)
	viewer_panel.size = Vector2(viewport_size.x - margin * 2.0, viewer_height)
