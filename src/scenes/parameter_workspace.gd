class_name ParameterWorkspace
extends CanvasLayer

const UI_AMBER := Color(0.92549, 0.619608, 0.0, 1.0)
const UI_AMBER_BRIGHT := Color(1.0, 0.72, 0.04, 1.0)
const UI_DARK := Color(0.035, 0.045, 0.05, 1.0)
const UI_PANEL := Color(0.065, 0.078, 0.082, 0.98)
const UI_BORDER := Color(0.19, 0.23, 0.24, 1.0)
const UI_TEXT := Color(0.78, 0.81, 0.82, 1.0)
const UI_MUTED := Color(0.39, 0.43, 0.44, 1.0)

var root: Control
var title_label: Label
var preview_title_label: Label
var parameter_title_label: Label
var preview_panel: PanelContainer
var preview_texture: TextureRect
var preview_empty_label: Label
var parameters_host: PanelContainer
var viewer_button: Button
var load_preset_button: Button
var save_preset_button: Button
var quit_button: Button
var french_button: Button
var english_button: Button
var german_button: Button
var generate_button: Button
var random_button: Button
var save_planet_button: Button


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


func style_button(button: Button, compact: bool = false, primary: bool = false) -> void:
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(90 if compact else 185, 34 if compact else 46)
	button.add_theme_color_override("font_color", UI_DARK if primary else UI_AMBER)
	button.add_theme_color_override("font_hover_color", UI_DARK)
	button.add_theme_color_override("font_pressed_color", UI_DARK)
	button.add_theme_color_override("font_disabled_color", UI_MUTED)
	button.add_theme_font_size_override("font_size", 17 if compact else 22)
	var normal_background := UI_AMBER if primary else Color(0.04, 0.05, 0.055, 1.0)
	button.add_theme_stylebox_override("normal", _panel_style(normal_background, UI_AMBER, 2, 4.0))
	button.add_theme_stylebox_override("hover", _panel_style(UI_AMBER_BRIGHT, UI_AMBER_BRIGHT, 2, 4.0))
	button.add_theme_stylebox_override("pressed", _panel_style(UI_AMBER, UI_AMBER, 2, 4.0))
	button.add_theme_stylebox_override("disabled", _panel_style(Color(0.05, 0.06, 0.065, 1.0), UI_BORDER, 1, 4.0))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _build_interface() -> void:
	root = Control.new()
	root.name = "ParameterWorkspace"
	root.theme = load("res://data/font/font.tres")
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var background := ColorRect.new()
	background.color = UI_DARK
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var header := PanelContainer.new()
	header.name = "Header"
	header.add_theme_stylebox_override("panel", _panel_style(Color(0.045, 0.055, 0.06, 1.0), UI_BORDER, 2, 10.0))
	root.add_child(header)
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 8)
	header.add_child(header_row)
	title_label = Label.new()
	title_label.text = "PLANET GENERATOR"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.add_theme_color_override("font_color", UI_AMBER)
	title_label.add_theme_font_size_override("font_size", 32)
	header_row.add_child(title_label)
	load_preset_button = Button.new()
	style_button(load_preset_button, true)
	header_row.add_child(load_preset_button)
	save_preset_button = Button.new()
	style_button(save_preset_button, true)
	header_row.add_child(save_preset_button)
	viewer_button = Button.new()
	style_button(viewer_button, true)
	header_row.add_child(viewer_button)
	french_button = Button.new()
	french_button.text = "FR"
	style_button(french_button, true)
	french_button.custom_minimum_size.x = 52
	header_row.add_child(french_button)
	english_button = Button.new()
	english_button.text = "EN"
	style_button(english_button, true)
	english_button.custom_minimum_size.x = 52
	header_row.add_child(english_button)
	german_button = Button.new()
	german_button.text = "DE"
	style_button(german_button, true)
	german_button.custom_minimum_size.x = 52
	header_row.add_child(german_button)
	quit_button = Button.new()
	style_button(quit_button, true)
	header_row.add_child(quit_button)

	preview_panel = PanelContainer.new()
	preview_panel.name = "PreviewPanel"
	var preview_style := _panel_style(Color(0.045, 0.055, 0.06, 1.0), UI_BORDER, 2, 2.0)
	preview_style.content_margin_top = 38.0
	preview_panel.add_theme_stylebox_override("panel", preview_style)
	preview_panel.clip_contents = true
	root.add_child(preview_panel)
	preview_texture = TextureRect.new()
	preview_texture.name = "PreviewTexture"
	preview_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_panel.add_child(preview_texture)
	preview_empty_label = Label.new()
	preview_empty_label.name = "PreviewEmptyState"
	preview_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	preview_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	preview_empty_label.add_theme_color_override("font_color", UI_MUTED)
	preview_empty_label.add_theme_font_size_override("font_size", 24)
	preview_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_panel.add_child(preview_empty_label)
	preview_title_label = Label.new()
	preview_title_label.name = "PreviewTitle"
	preview_title_label.add_theme_color_override("font_color", UI_AMBER)
	preview_title_label.add_theme_font_size_override("font_size", 20)
	preview_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(preview_title_label)

	parameters_host = PanelContainer.new()
	parameters_host.name = "ParametersHost"
	var parameter_style := _panel_style(Color(0.045, 0.055, 0.06, 1.0), UI_BORDER, 2, 8.0)
	parameter_style.content_margin_top = 42.0
	parameters_host.add_theme_stylebox_override("panel", parameter_style)
	root.add_child(parameters_host)
	parameter_title_label = Label.new()
	parameter_title_label.name = "ParameterTitle"
	parameter_title_label.add_theme_color_override("font_color", UI_AMBER)
	parameter_title_label.add_theme_font_size_override("font_size", 22)
	parameter_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(parameter_title_label)

	var actions := PanelContainer.new()
	actions.name = "Actions"
	actions.add_theme_stylebox_override("panel", _panel_style(Color(0.045, 0.055, 0.06, 1.0), UI_BORDER, 2, 10.0))
	root.add_child(actions)
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 12)
	actions.add_child(action_row)
	generate_button = Button.new()
	generate_button.name = "GenerateButton"
	style_button(generate_button, false, true)
	action_row.add_child(generate_button)
	random_button = Button.new()
	random_button.name = "RandomButton"
	style_button(random_button)
	action_row.add_child(random_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_row.add_child(spacer)
	save_planet_button = Button.new()
	save_planet_button.name = "SavePlanetButton"
	style_button(save_planet_button)
	action_row.add_child(save_planet_button)


func _layout_interface() -> void:
	if root == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var margin := 22.0
	var header_height := 70.0
	var body_top := margin + header_height + 14.0
	var action_height := 70.0
	var action_top := viewport_size.y - action_height - margin
	var body_height := action_top - body_top - 10.0
	var right_width := clampf(viewport_size.x * 0.34, 430.0, 500.0)
	var gap := 12.0
	var left_width := viewport_size.x - margin * 2.0 - right_width - gap
	var header := root.get_node("Header") as Control
	header.position = Vector2(margin, margin)
	header.size = Vector2(viewport_size.x - margin * 2.0, header_height)
	preview_panel.position = Vector2(margin, body_top)
	preview_panel.size = Vector2(left_width, body_height)
	preview_title_label.position = Vector2(margin + 12.0, body_top + 8.0)
	preview_title_label.size = Vector2(left_width - 24.0, 26.0)
	parameters_host.position = Vector2(margin + left_width + gap, body_top)
	parameters_host.size = Vector2(right_width, body_height)
	parameter_title_label.position = Vector2(parameters_host.position.x + 14.0, body_top + 8.0)
	parameter_title_label.size = Vector2(right_width - 28.0, 28.0)
	var actions := root.get_node("Actions") as Control
	actions.position = Vector2(margin, action_top)
	actions.size = Vector2(viewport_size.x - margin * 2.0, action_height)


func set_preview_texture(texture: Texture2D) -> void:
	preview_texture.texture = texture
	preview_texture.visible = texture != null
	preview_empty_label.visible = texture == null

