class_name ReferenceViewerWorkspace
extends CanvasLayer

const UI_AMBER := Color(0.92549, 0.619608, 0.0, 1.0)
const UI_AMBER_BRIGHT := Color(1.0, 0.72, 0.04, 1.0)
const UI_DARK := Color(0.035, 0.045, 0.05, 1.0)
const UI_PANEL := Color(0.065, 0.078, 0.082, 0.98)
const UI_PANEL_ALT := Color(0.09, 0.105, 0.11, 0.98)
const UI_BORDER := Color(0.19, 0.23, 0.24, 1.0)
const UI_TEXT := Color(0.78, 0.81, 0.82, 1.0)
const UI_MUTED := Color(0.39, 0.43, 0.44, 1.0)

var root: Control
var header_panel: PanelContainer
var phase_label: Label
var memory_label: Label
var status_dot: Label
var progress_bar: ProgressBar
var parameters_button: Button
var cancel_button: Button
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
	get_viewport().size_changed.connect(_layout_interface)
	_layout_interface()


func _panel_style(
	background: Color = UI_PANEL,
	border: Color = UI_BORDER,
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
	option.custom_minimum_size = Vector2(250, 36)
	option.add_theme_color_override("font_color", UI_TEXT)
	option.add_theme_color_override("font_hover_color", UI_AMBER_BRIGHT)
	option.add_theme_font_size_override("font_size", 18)
	var field_style := _panel_style(Color(0.045, 0.055, 0.06, 1.0), UI_BORDER, 1, 6.0)
	for style_name in ["normal", "normal_mirrored", "pressed", "pressed_mirrored", "hover", "hover_mirrored", "hover_pressed", "hover_pressed_mirrored", "disabled", "disabled_mirrored"]:
		option.add_theme_stylebox_override(style_name, field_style)
	option.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


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
	title.add_theme_font_size_override("font_size", 16)
	content.add_child(title)
	return content


func _build_interface() -> void:
	root = Control.new()
	root.name = "ReferenceViewer"
	root.theme = load("res://data/font/font.tres")
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var background := ColorRect.new()
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
	progress_bar.add_theme_font_size_override("font_size", 13)
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
	var controls_row := HBoxContainer.new()
	controls_row.add_theme_constant_override("separation", 10)
	viewer_box.add_child(controls_row)
	var base_group := _make_group(controls_row, 290)
	base_title_label = base_group.get_child(0) as Label
	base_select = OptionButton.new()
	base_select.name = "BaseSelect"
	_style_option(base_select)
	base_group.add_child(base_select)
	var overlay_group := _make_group(controls_row, 290)
	overlay_title_label = overlay_group.get_child(0) as Label
	overlay_select = OptionButton.new()
	overlay_select.name = "OverlaySelect"
	_style_option(overlay_select)
	overlay_group.add_child(overlay_select)
	var opacity_group := _make_group(controls_row, 285)
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
	opacity_slider.custom_minimum_size = Vector2(205, 24)
	opacity_slider.add_theme_icon_override("grabber", load("res://data/img/UI/Range/Grabber.png"))
	opacity_slider.add_theme_icon_override("grabber_highlight", load("res://data/img/UI/Range/Grabber_grabbed.png"))
	opacity_slider.add_theme_stylebox_override("slider", load("res://data/styles/slider_non_highlight.tres"))
	opacity_slider.add_theme_stylebox_override("grabber_area", load("res://data/styles/slider_highlight.tres"))
	opacity_row.add_child(opacity_slider)
	opacity_percent_label = Label.new()
	opacity_percent_label.custom_minimum_size.x = 46
	opacity_percent_label.text = "65%"
	opacity_percent_label.add_theme_color_override("font_color", UI_TEXT)
	opacity_percent_label.add_theme_font_size_override("font_size", 18)
	opacity_row.add_child(opacity_percent_label)
	var zoom_group := _make_group(controls_row, 250)
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
	inspector_label.add_theme_font_size_override("font_size", 16)
	inspector_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inspector_panel.add_child(inspector_label)
	help_label = Label.new()
	help_label.add_theme_color_override("font_color", UI_MUTED)
	help_label.add_theme_font_size_override("font_size", 14)
	viewer_box.add_child(help_label)


func _layout_interface() -> void:
	if root == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var margin := 22.0
	var header_height := 88.0
	var viewer_height := clampf(viewport_size.y * 0.255, 205.0, 245.0)
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

