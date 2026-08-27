class_name ParameterWorkspace
extends CanvasLayer

signal generate_requested
signal save_planet_requested
signal load_preset_requested
signal save_preset_requested
signal viewer_requested
signal quit_requested
signal language_requested(code: String)
signal batch_start_requested(count: int, first_seed: int)
signal batch_cancel_requested

const UI_AMBER := Color(0.92549, 0.619608, 0.0, 1.0)
const UI_AMBER_BRIGHT := Color(1.0, 0.72, 0.04, 1.0)
const UI_DARK := Color(0.035, 0.045, 0.05, 1.0)
const UI_PANEL := Color(0.065, 0.078, 0.082, 0.98)
const UI_PANEL_ALT := Color(0.09, 0.105, 0.11, 0.98)
const UI_BORDER := Color(0.19, 0.23, 0.24, 1.0)
const UI_TEXT := Color(0.78, 0.81, 0.82, 1.0)
const UI_TEXT_BRIGHT := Color(0.92, 0.94, 0.94, 1.0)
const UI_MUTED := Color(0.39, 0.43, 0.44, 1.0)
const PARAMETER_SCHEMA := preload("res://src/scenes/planet_parameter_schema.gd")
const PLANET_TEMPLATES := preload("res://src/classes/classes_io/planet_templates.gd")
const EXPORT_CATALOG := preload("res://src/classes/classes_io/export_catalog.gd")

var root: Control
var title_label: Label
var preview_title_label: Label
var preview_shortcuts_label: Label
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
var random_name_button: Button
var random_seed_button: Button
var save_planet_button: Button
var template_select: OptionButton
var template_apply_button: Button
var smart_random_button: Button
var batch_toggle_button: Button
var batch_panel: PanelContainer
var batch_title_label: Label
var batch_count_label: Label
var batch_seed_label: Label
var batch_count_spin: SpinBox
var batch_seed_spin: SpinBox
var batch_status_label: Label
var batch_start_button: Button
var export_preset_select: OptionButton

var _parameter_tree: VBoxContainer
var _controls: Dictionary = {}
var _value_labels: Dictionary = {}
var _category_buttons: Dictionary = {}
var _category_bodies: Dictionary = {}
var _category_panels: Dictionary = {}
var _option_definitions: Dictionary = {}
var _spinbox_arrows_icon: Texture2D
var _refresh_icon: Texture2D
var _batch_running: bool = false
var _batch_status_key: String = "BATCH_READY"
var _batch_status_args: Dictionary = {}


func _ready() -> void:
	layer = 40
	_build_interface()
	_build_parameters_from_schema()
	_connect_actions()
	refresh_translations()
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


func _style_language_button(
	button: Button,
	normal_path: String,
	hover_path: String,
	pressed_path: String,
	tooltip: String
) -> void:
	button.focus_mode = Control.FOCUS_NONE
	button.text = ""
	button.tooltip_text = tooltip
	var normal_texture: Texture2D = load(normal_path) as Texture2D
	if normal_texture != null:
		button.custom_minimum_size = Vector2(normal_texture.get_width(), normal_texture.get_height()) * 0.8
	else:
		button.custom_minimum_size = Vector2(56, 40)
	button.add_theme_stylebox_override("normal", _flag_style(normal_path))
	button.add_theme_stylebox_override("hover", _flag_style(hover_path))
	button.add_theme_stylebox_override("pressed", _flag_style(pressed_path))
	button.add_theme_stylebox_override("disabled", _flag_style(normal_path))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _flag_style(texture_path: String) -> StyleBoxTexture:
	var style := StyleBoxTexture.new()
	var flag_texture: Texture2D = load(texture_path) as Texture2D
	style.texture = flag_texture
	return style


func _style_line_edit(edit: LineEdit) -> void:
	edit.custom_minimum_size.y = 40
	edit.add_theme_color_override("font_color", UI_TEXT_BRIGHT)
	edit.add_theme_color_override("font_selected_color", UI_TEXT_BRIGHT)
	edit.add_theme_color_override("font_placeholder_color", Color(0.53, 0.57, 0.58, 1.0))
	edit.add_theme_color_override("font_uneditable_color", UI_MUTED)
	edit.add_theme_color_override("caret_color", UI_AMBER_BRIGHT)
	edit.add_theme_color_override("selection_color", Color(0.42, 0.28, 0.0, 1.0))
	edit.add_theme_font_size_override("font_size", 20)
	edit.add_theme_stylebox_override("normal", _panel_style(Color(0.055, 0.065, 0.07, 1.0), UI_AMBER, 1, 8.0))
	edit.add_theme_stylebox_override("focus", _panel_style(Color(0.035, 0.045, 0.05, 1.0), UI_AMBER_BRIGHT, 2, 8.0))
	edit.add_theme_stylebox_override("read_only", _panel_style(Color(0.045, 0.052, 0.056, 1.0), UI_BORDER, 1, 8.0))


func _style_spinbox(spin: SpinBox) -> void:
	_style_line_edit(spin.get_line_edit())
	if _spinbox_arrows_icon == null:
		_spinbox_arrows_icon = _make_spinbox_arrows_icon()
	for icon_name in ["updown", "updown_hover", "updown_pressed", "updown_disabled"]:
		spin.add_theme_icon_override(icon_name, _spinbox_arrows_icon)


func _style_refresh_button(button: Button, accessible_name: String) -> void:
	style_button(button, true)
	if _refresh_icon == null:
		_refresh_icon = _make_refresh_icon()
	button.text = ""
	button.tooltip_text = accessible_name
	button.custom_minimum_size = Vector2(46, 40)
	button.icon = _refresh_icon
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.add_theme_constant_override("icon_max_width", 20)
	button.add_theme_color_override("icon_normal_color", UI_AMBER_BRIGHT)
	button.add_theme_color_override("icon_hover_color", UI_DARK)
	button.add_theme_color_override("icon_pressed_color", UI_DARK)
	button.add_theme_color_override("icon_disabled_color", UI_MUTED)


func _make_spinbox_arrows_icon() -> Texture2D:
	var image := Image.create(14, 30, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	_fill_pixel_rect(image, Rect2i(6, 6, 2, 1), UI_AMBER_BRIGHT)
	_fill_pixel_rect(image, Rect2i(5, 7, 4, 1), UI_AMBER_BRIGHT)
	_fill_pixel_rect(image, Rect2i(4, 8, 6, 1), UI_AMBER_BRIGHT)
	_fill_pixel_rect(image, Rect2i(3, 9, 8, 1), UI_AMBER_BRIGHT)
	_fill_pixel_rect(image, Rect2i(3, 20, 8, 1), UI_AMBER_BRIGHT)
	_fill_pixel_rect(image, Rect2i(4, 21, 6, 1), UI_AMBER_BRIGHT)
	_fill_pixel_rect(image, Rect2i(5, 22, 4, 1), UI_AMBER_BRIGHT)
	_fill_pixel_rect(image, Rect2i(6, 23, 2, 1), UI_AMBER_BRIGHT)
	return ImageTexture.create_from_image(image)


func _make_refresh_icon() -> Texture2D:
	var image := Image.create(18, 18, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	var white := Color.WHITE
	_fill_pixel_rect(image, Rect2i(5, 3, 7, 2), white)
	_fill_pixel_rect(image, Rect2i(3, 5, 2, 7), white)
	_fill_pixel_rect(image, Rect2i(5, 12, 7, 2), white)
	_fill_pixel_rect(image, Rect2i(12, 9, 2, 4), white)
	_fill_pixel_rect(image, Rect2i(11, 4, 5, 2), white)
	_fill_pixel_rect(image, Rect2i(12, 6, 4, 1), white)
	_fill_pixel_rect(image, Rect2i(13, 7, 3, 1), white)
	_fill_pixel_rect(image, Rect2i(14, 8, 2, 1), white)
	return ImageTexture.create_from_image(image)


func _fill_pixel_rect(image: Image, rect: Rect2i, color: Color) -> void:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			image.set_pixel(x, y, color)


func _style_option(option: OptionButton) -> void:
	option.focus_mode = Control.FOCUS_NONE
	option.custom_minimum_size.y = 44
	option.add_theme_color_override("font_color", UI_TEXT_BRIGHT)
	option.add_theme_color_override("font_hover_color", UI_AMBER_BRIGHT)
	option.add_theme_color_override("font_pressed_color", UI_AMBER_BRIGHT)
	option.add_theme_font_size_override("font_size", 21)
	var field_style := _panel_style(Color(0.035, 0.045, 0.05, 1.0), UI_BORDER, 1, 9.0)
	for style_name in ["normal", "normal_mirrored", "pressed", "pressed_mirrored", "hover", "hover_mirrored", "hover_pressed", "hover_pressed_mirrored", "disabled", "disabled_mirrored"]:
		option.add_theme_stylebox_override(style_name, field_style)
	option.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_style_popup_menu(option.get_popup(), 420)


func _style_popup_menu(popup: PopupMenu, minimum_width: int) -> void:
	popup.min_size = Vector2i(minimum_width, 0)
	popup.max_size = Vector2i(720, 620)
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


func _style_slider(slider: HSlider) -> void:
	slider.custom_minimum_size.y = 25
	slider.add_theme_icon_override("grabber", load("res://data/img/UI/Range/Grabber.png"))
	slider.add_theme_icon_override("grabber_highlight", load("res://data/img/UI/Range/Grabber_grabbed.png"))
	slider.add_theme_stylebox_override("slider", load("res://data/styles/slider_non_highlight.tres"))
	slider.add_theme_stylebox_override("grabber_area", load("res://data/styles/slider_highlight.tres"))


func _build_interface() -> void:
	root = Control.new()
	root.name = "ParameterWorkspace"
	var workspace_theme := (load("res://data/font/font.tres") as Theme).duplicate()
	workspace_theme.default_font_size = 16
	root.theme = workspace_theme
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
	_style_language_button(
		french_button,
		"res://data/img/UI/Flags/fra.png",
		"res://data/img/UI/Flags/fra_hover.png",
		"res://data/img/UI/Flags/fra_pressed.png",
		"Français"
	)
	header_row.add_child(french_button)
	english_button = Button.new()
	_style_language_button(
		english_button,
		"res://data/img/UI/Flags/can.png",
		"res://data/img/UI/Flags/can_hover.png",
		"res://data/img/UI/Flags/can_pressed.png",
		"English"
	)
	header_row.add_child(english_button)
	german_button = Button.new()
	_style_language_button(
		german_button,
		"res://data/img/UI/Flags/deu.png",
		"res://data/img/UI/Flags/deu_hover.png",
		"res://data/img/UI/Flags/deu_pressed.png",
		"Deutsch"
	)
	header_row.add_child(german_button)
	quit_button = Button.new()
	style_button(quit_button, true)
	header_row.add_child(quit_button)

	preview_panel = PanelContainer.new()
	preview_panel.name = "PreviewPanel"
	var preview_style := _panel_style(Color(0.045, 0.055, 0.06, 1.0), UI_BORDER, 2, 2.0)
	preview_style.content_margin_top = 62.0
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
	preview_shortcuts_label = Label.new()
	preview_shortcuts_label.name = "PreviewShortcuts"
	preview_shortcuts_label.add_theme_color_override("font_color", UI_MUTED)
	preview_shortcuts_label.add_theme_font_size_override("font_size", 16)
	preview_shortcuts_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(preview_shortcuts_label)

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
	random_button.focus_mode = Control.FOCUS_NONE
	random_button.text = ""
	random_button.tooltip_text = tr("RANDOMISE")
	random_button.custom_minimum_size = Vector2(42, 30)
	random_button.add_theme_stylebox_override("normal", _flag_style("res://data/img/UI/button/random_btn.png"))
	random_button.add_theme_stylebox_override("hover", _flag_style("res://data/img/UI/button/random_btn_hover.png"))
	random_button.add_theme_stylebox_override("pressed", _flag_style("res://data/img/UI/button/random_btn_pressed.png"))
	random_button.add_theme_stylebox_override("disabled", _flag_style("res://data/img/UI/button/random_btn.png"))
	random_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	action_row.add_child(random_button)
	template_select = OptionButton.new()
	template_select.name = "PlanetTemplateSelect"
	template_select.custom_minimum_size = Vector2(220, 40)
	_style_option(template_select)
	action_row.add_child(template_select)
	template_apply_button = Button.new()
	template_apply_button.name = "ApplyTemplateButton"
	style_button(template_apply_button, true)
	template_apply_button.custom_minimum_size.x = 135
	action_row.add_child(template_apply_button)
	smart_random_button = Button.new()
	smart_random_button.name = "SmartRandomButton"
	style_button(smart_random_button, true)
	smart_random_button.custom_minimum_size.x = 150
	action_row.add_child(smart_random_button)
	batch_toggle_button = Button.new()
	batch_toggle_button.name = "BatchToggleButton"
	style_button(batch_toggle_button, true)
	batch_toggle_button.custom_minimum_size.x = 110
	action_row.add_child(batch_toggle_button)
	export_preset_select = OptionButton.new()
	export_preset_select.name = "ExportPresetSelect"
	_style_option(export_preset_select)
	export_preset_select.custom_minimum_size = Vector2(165, 46)
	action_row.add_child(export_preset_select)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_row.add_child(spacer)
	save_planet_button = Button.new()
	save_planet_button.name = "SavePlanetButton"
	style_button(save_planet_button)
	action_row.add_child(save_planet_button)

	_build_batch_panel()


func _build_batch_panel() -> void:
	batch_panel = PanelContainer.new()
	batch_panel.name = "BatchPanel"
	batch_panel.visible = false
	batch_panel.add_theme_stylebox_override(
		"panel",
		_panel_style(Color(0.045, 0.055, 0.06, 1.0), UI_AMBER, 2, 12.0)
	)
	root.add_child(batch_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	batch_panel.add_child(box)

	batch_title_label = Label.new()
	batch_title_label.add_theme_color_override("font_color", UI_AMBER)
	batch_title_label.add_theme_font_size_override("font_size", 22)
	box.add_child(batch_title_label)

	var count_row := HBoxContainer.new()
	count_row.add_theme_constant_override("separation", 10)
	box.add_child(count_row)
	batch_count_label = Label.new()
	batch_count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	batch_count_label.add_theme_color_override("font_color", UI_TEXT)
	count_row.add_child(batch_count_label)
	batch_count_spin = SpinBox.new()
	batch_count_spin.custom_minimum_size = Vector2(130, 34)
	batch_count_spin.min_value = 1.0
	batch_count_spin.max_value = 500.0
	batch_count_spin.step = 1.0
	batch_count_spin.value = 10.0
	_style_spinbox(batch_count_spin)
	count_row.add_child(batch_count_spin)

	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 10)
	box.add_child(seed_row)
	batch_seed_label = Label.new()
	batch_seed_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	batch_seed_label.add_theme_color_override("font_color", UI_TEXT)
	seed_row.add_child(batch_seed_label)
	batch_seed_spin = SpinBox.new()
	batch_seed_spin.custom_minimum_size = Vector2(130, 34)
	batch_seed_spin.min_value = 0.0
	batch_seed_spin.max_value = 2147483647.0
	batch_seed_spin.step = 1.0
	batch_seed_spin.value = 1000.0
	_style_spinbox(batch_seed_spin)
	seed_row.add_child(batch_seed_spin)

	batch_status_label = Label.new()
	batch_status_label.add_theme_color_override("font_color", Color(0.58, 0.62, 0.63, 1.0))
	batch_status_label.add_theme_font_size_override("font_size", 18)
	batch_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	batch_status_label.custom_minimum_size.y = 42.0
	box.add_child(batch_status_label)

	batch_start_button = Button.new()
	batch_start_button.name = "BatchStartButton"
	style_button(batch_start_button, true)
	batch_start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(batch_start_button)


func _build_parameters_from_schema() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "ParameterScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parameters_host.add_child(scroll)
	_parameter_tree = VBoxContainer.new()
	_parameter_tree.name = "ParameterTree"
	_parameter_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_parameter_tree.add_theme_constant_override("separation", 8)
	scroll.add_child(_parameter_tree)

	for category in PARAMETER_SCHEMA.CATEGORY_ORDER:
		_create_category(str(category))
	for definition in PARAMETER_SCHEMA.DEFINITIONS:
		_create_parameter(definition)
	var planet_type_control: OptionButton = _controls.get("planet_type") as OptionButton
	if planet_type_control != null:
		planet_type_control.item_selected.connect(func(_index: int) -> void:
			_apply_planet_type_ui_state()
		)
	_apply_planet_type_ui_state()


func _create_category(category: String) -> void:
	var panel := PanelContainer.new()
	panel.name = category.capitalize() + "Category"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _panel_style(UI_PANEL_ALT, UI_BORDER, 1, 6.0))
	_parameter_tree.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	panel.add_child(box)
	var header := Button.new()
	header.name = "Header"
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	style_button(header, true)
	header.custom_minimum_size = Vector2(0, 32)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(header)
	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", 8)
	box.add_child(body)
	header.pressed.connect(func() -> void:
		body.visible = not body.visible
	)
	_category_buttons[category] = header
	_category_bodies[category] = body
	_category_panels[category] = panel


func _create_parameter(definition: Dictionary) -> void:
	var key := str(definition["key"])
	var category := str(definition["category"])
	var body := _category_bodies.get(category) as VBoxContainer
	if body == null:
		push_error("[ParameterWorkspace] Missing category: " + category)
		return
	var row := VBoxContainer.new()
	row.name = key
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 3)
	body.add_child(row)

	var label := Label.new()
	label.name = "Label"
	label.add_theme_color_override("font_color", UI_TEXT_BRIGHT)
	label.add_theme_font_size_override("font_size", 18)
	row.add_child(label)
	_value_labels[key] = label

	var kind := str(definition.get("kind", "slider"))
	match kind:
		"text":
			var hbox := HBoxContainer.new()
			hbox.add_theme_constant_override("separation", 6)
			row.add_child(hbox)
			var edit := LineEdit.new()
			edit.name = "Value"
			edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			edit.text = str(definition.get("default", ""))
			_style_line_edit(edit)
			hbox.add_child(edit)
			random_name_button = Button.new()
			random_name_button.name = "RandomNameButton"
			_style_refresh_button(random_name_button, tr("UI_TOOLTIP_RANDOM_NAME"))
			random_name_button.pressed.connect(randomize_name)
			hbox.add_child(random_name_button)
			_controls[key] = edit
		"spinbox":
			var hbox := HBoxContainer.new()
			hbox.add_theme_constant_override("separation", 6)
			row.add_child(hbox)
			var spin := SpinBox.new()
			spin.name = "Value"
			spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			spin.min_value = float(definition.get("min", 0.0))
			spin.max_value = float(definition.get("max", 100.0))
			spin.step = float(definition.get("step", 1.0))
			spin.value = float(definition.get("default", 0.0))
			_style_spinbox(spin)
			hbox.add_child(spin)
			random_seed_button = Button.new()
			random_seed_button.name = "RandomSeedButton"
			_style_refresh_button(random_seed_button, tr("UI_TOOLTIP_RANDOM_SEED"))
			random_seed_button.pressed.connect(randomize_seed)
			hbox.add_child(random_seed_button)
			_controls[key] = spin
		"option":
			var option := OptionButton.new()
			option.name = "Value"
			option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_style_option(option)
			var options: Array = definition.get("options", [])
			for option_definition in options:
				option.add_item(str(option_definition[0]), int(option_definition[1]))
			option.select(_option_index_for_id(option, int(definition.get("default", 0))))
			row.add_child(option)
			_controls[key] = option
			_option_definitions[key] = options
		_:
			var slider := HSlider.new()
			slider.name = "Value"
			slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			slider.min_value = float(definition.get("min", 0.0))
			slider.max_value = float(definition.get("max", 100.0))
			slider.step = float(definition.get("step", 1.0))
			slider.value = float(definition.get("default", 0.0))
			_style_slider(slider)
			row.add_child(slider)
			_controls[key] = slider
			slider.value_changed.connect(func(_value: float) -> void:
				_refresh_parameter_label(key)
			)

	_refresh_parameter_label(key)


func _connect_actions() -> void:
	generate_button.pressed.connect(func() -> void: generate_requested.emit())
	random_button.pressed.connect(randomize_parameters)
	template_apply_button.pressed.connect(apply_selected_template)
	smart_random_button.pressed.connect(smart_randomize_parameters)
	save_planet_button.pressed.connect(func() -> void: save_planet_requested.emit())
	load_preset_button.pressed.connect(func() -> void: load_preset_requested.emit())
	save_preset_button.pressed.connect(func() -> void: save_preset_requested.emit())
	viewer_button.pressed.connect(func() -> void: viewer_requested.emit())
	quit_button.pressed.connect(func() -> void: quit_requested.emit())
	french_button.pressed.connect(func() -> void: language_requested.emit("fr"))
	english_button.pressed.connect(func() -> void: language_requested.emit("en"))
	german_button.pressed.connect(func() -> void: language_requested.emit("de"))
	batch_toggle_button.pressed.connect(toggle_batch_panel)
	batch_start_button.pressed.connect(_on_batch_start_pressed)


func toggle_batch_panel() -> void:
	if batch_panel == null:
		return
	batch_panel.visible = not batch_panel.visible


func close_batch_panel() -> void:
	if batch_panel != null and not _batch_running:
		batch_panel.visible = false


func is_batch_panel_visible() -> bool:
	return batch_panel != null and batch_panel.visible


func _on_batch_start_pressed() -> void:
	if _batch_running:
		batch_cancel_requested.emit()
		return
	batch_start_requested.emit(int(batch_count_spin.value), int(batch_seed_spin.value))


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
	preview_shortcuts_label.position = Vector2(margin + 12.0, body_top + 34.0)
	preview_shortcuts_label.size = Vector2(left_width - 24.0, 22.0)
	parameters_host.position = Vector2(margin + left_width + gap, body_top)
	parameters_host.size = Vector2(right_width, body_height)
	parameter_title_label.position = Vector2(parameters_host.position.x + 14.0, body_top + 8.0)
	parameter_title_label.size = Vector2(right_width - 28.0, 28.0)
	var actions := root.get_node("Actions") as Control
	actions.position = Vector2(margin, action_top)
	actions.size = Vector2(viewport_size.x - margin * 2.0, action_height)
	if batch_panel != null:
		var batch_size := Vector2(minf(430.0, viewport_size.x - margin * 2.0), 218.0)
		batch_panel.size = batch_size
		batch_panel.position = Vector2(
			maxf(margin, (viewport_size.x - batch_size.x) * 0.5),
			maxf(body_top, action_top - batch_size.y - 10.0)
		)


func set_preview_texture(texture: Texture2D) -> void:
	preview_texture.texture = texture
	preview_texture.visible = texture != null
	preview_empty_label.visible = texture == null


func get_value(key: String) -> Variant:
	var control: Control = _controls.get(key) as Control
	if control == null:
		push_error("[ParameterWorkspace] Unknown parameter: " + key)
		return null
	if control is LineEdit:
		return (control as LineEdit).text
	if control is OptionButton:
		return (control as OptionButton).get_selected_id()
	if control is Range:
		return (control as Range).value
	return null


func set_value(key: String, value: Variant) -> bool:
	var control: Control = _controls.get(key) as Control
	if control == null:
		return false
	if control is LineEdit:
		(control as LineEdit).text = str(value)
	elif control is OptionButton:
		var option := control as OptionButton
		option.select(_option_index_for_id(option, int(value)))
	elif control is Range:
		(control as Range).value = float(value)
	else:
		return false
	_refresh_parameter_label(key)
	if key == "planet_type":
		_apply_planet_type_ui_state()
	return true


func get_values() -> Dictionary:
	var values: Dictionary = {}
	for key in PARAMETER_SCHEMA.keys():
		values[key] = get_value(key)
	return values


func apply_values(values: Dictionary) -> void:
	for key in PARAMETER_SCHEMA.keys():
		if values.has(key):
			set_value(key, values[key])
	refresh_translations()


func apply_selected_template() -> void:
	if template_select == null or template_select.selected < 0:
		return
	var template_name: String = str(template_select.get_item_metadata(template_select.selected))
	if template_name.is_empty():
		return
	apply_values(PLANET_TEMPLATES.values(template_name))


func smart_randomize_parameters() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var values: Dictionary = PLANET_TEMPLATES.smart_random(rng)
	var template_name: String = str(values.get("template_name", PLANET_TEMPLATES.ORDER[0]))
	values.erase("template_name")
	_select_template_by_name(template_name)
	apply_values(values)
	randomize_seed()
	randomize_name()


func _refresh_template_items() -> void:
	if template_select == null:
		return
	var selected_name := ""
	if template_select.selected >= 0:
		selected_name = str(template_select.get_item_metadata(template_select.selected))
	template_select.clear()
	for template_name in PLANET_TEMPLATES.ORDER:
		var stable_name: String = str(template_name)
		template_select.add_item(tr(PLANET_TEMPLATES.translation_key(stable_name)))
		template_select.set_item_metadata(template_select.item_count - 1, stable_name)
	if selected_name.is_empty():
		selected_name = str(PLANET_TEMPLATES.ORDER[0])
	_select_template_by_name(selected_name)


func _select_template_by_name(template_name: String) -> void:
	if template_select == null:
		return
	for index in range(template_select.item_count):
		if str(template_select.get_item_metadata(index)) == template_name:
			template_select.select(index)
			return


func randomize_parameters() -> void:
	randomize()
	randomize_name()
	randomize_seed()
	for definition in PARAMETER_SCHEMA.DEFINITIONS:
		var key := str(definition["key"])
		if key in ["planet_name", "seed"] or not bool(definition.get("randomize", true)):
			continue
		var control: Control = _controls.get(key) as Control
		if control is HSlider:
			var slider := control as HSlider
			var steps := maxi(int(round((slider.max_value - slider.min_value) / slider.step)), 0)
			var random_step := randi_range(0, steps)
			slider.value = slider.min_value + float(random_step) * slider.step
		elif control is OptionButton:
			var option := control as OptionButton
			if option.item_count > 0:
				option.select(randi_range(0, option.item_count - 1))
	_apply_planet_type_ui_state()
	refresh_translations()


func randomize_seed() -> void:
	set_value("seed", randi())


func randomize_name() -> void:
	var prefixes: Array[String] = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Kepler", "Gliese", "Trappist", "HD", "Wolf", "Ross", "Luyten", "Kapteyn", "Proxima", "Sigma", "Tau", "Upsilon", "Vega", "Sirius", "Altair", "Deneb", "Rigel", "Betelgeuse", "Aldebaran", "Fomalhaut", "Pollux", "Arcturus", "Spica", "Antares", "VY Canis Majoris", "UY Scuti", "UY Aurigae", "Omega", "Nova", "Quasar", "Pulsar", "Magellan", "Andromeda", "Orion", "Pegasus", "Phoenix", "Centauri", "Draco", "Hydra", "Lyra", "Perseus", "Scorpius", "Taurus", "Ursa", "Virgo", "Zodiac"]
	var suffixes: Array[String] = ["Prime", "Major", "Minor", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "b", "c", "d"]
	var generated_name: String = prefixes[randi_range(0, prefixes.size() - 1)] + "-" + str(randi_range(1, 999))
	if randf() > 0.5:
		generated_name += " " + suffixes[randi_range(0, suffixes.size() - 1)]
	set_value("planet_name", generated_name)


func refresh_translations() -> void:
	if root == null:
		return
	preview_title_label.text = tr("VIEWER_PREVIEW")
	preview_shortcuts_label.text = tr("PARAMETER_PREVIEW_SHORTCUTS")
	parameter_title_label.text = tr("PARAMETRES")
	preview_empty_label.text = "%s\n%s" % [tr("VIEWER_EMPTY_TITLE"), tr("VIEWER_EMPTY_HINT")]
	load_preset_button.text = tr("LOAD_PRESET")
	save_preset_button.text = tr("SAVE_PRESET")
	viewer_button.text = tr("MAP_VIEWER_TITLE").to_upper()
	quit_button.text = tr("LEAVE")
	generate_button.text = tr("GENERER")
	random_button.text = ""
	random_button.tooltip_text = tr("RANDOMISE")
	template_apply_button.text = tr("TEMPLATE_APPLY")
	smart_random_button.text = tr("TEMPLATE_SMART_RANDOM")
	template_select.tooltip_text = tr("TEMPLATE_TOOLTIP")
	smart_random_button.tooltip_text = tr("TEMPLATE_SMART_RANDOM_TOOLTIP")
	batch_toggle_button.text = tr("BATCH_BUTTON")
	batch_title_label.text = tr("BATCH_TITLE")
	batch_count_label.text = tr("BATCH_COUNT")
	batch_seed_label.text = tr("BATCH_FIRST_SEED")
	batch_start_button.text = tr("BATCH_CANCEL") if _batch_running else tr("BATCH_START")
	_refresh_batch_status()
	save_planet_button.text = tr("SAUVEGARDER")
	_refresh_template_items()
	_refresh_export_preset_items()
	generate_button.tooltip_text = tr("UI_TOOLTIP_GENERATE")
	random_button.tooltip_text = tr("UI_TOOLTIP_RANDOM")
	if random_name_button != null:
		random_name_button.tooltip_text = tr("UI_TOOLTIP_RANDOM_NAME")
	if random_seed_button != null:
		random_seed_button.tooltip_text = tr("UI_TOOLTIP_RANDOM_SEED")
	load_preset_button.tooltip_text = tr("UI_TOOLTIP_LOAD_PRESET")
	save_preset_button.tooltip_text = tr("UI_TOOLTIP_SAVE_PRESET")
	viewer_button.tooltip_text = tr("UI_TOOLTIP_VIEWER")
	batch_toggle_button.tooltip_text = tr("UI_TOOLTIP_BATCH")
	save_planet_button.tooltip_text = tr("UI_TOOLTIP_SAVE_PLANET")
	if export_preset_select != null:
		export_preset_select.tooltip_text = tr("UI_TOOLTIP_EXPORT_PRESET")

	for category in PARAMETER_SCHEMA.CATEGORY_ORDER:
		var category_key := str(category)
		var button := _category_buttons.get(category_key) as Button
		if button != null:
			button.text = tr(str(PARAMETER_SCHEMA.CATEGORY_LABELS[category_key])).to_upper()
	for definition in PARAMETER_SCHEMA.DEFINITIONS:
		var key := str(definition["key"])
		_refresh_parameter_label(key)
		if str(definition.get("kind", "slider")) == "option":
			_refresh_option_items(key)


func set_actions_enabled(enabled: bool) -> void:
	generate_button.disabled = not enabled
	random_button.disabled = not enabled
	template_select.disabled = not enabled
	template_apply_button.disabled = not enabled
	smart_random_button.disabled = not enabled
	load_preset_button.disabled = not enabled
	save_preset_button.disabled = not enabled
	viewer_button.disabled = not enabled
	batch_toggle_button.disabled = not enabled and not _batch_running
	batch_count_spin.editable = enabled and not _batch_running
	batch_seed_spin.editable = enabled and not _batch_running
	batch_start_button.disabled = not enabled and not _batch_running
	if export_preset_select != null:
		export_preset_select.disabled = not enabled


func get_export_preset() -> String:
	if export_preset_select == null or export_preset_select.selected < 0:
		return EXPORT_CATALOG.PRESET_STANDARD
	return str(export_preset_select.get_item_metadata(export_preset_select.selected))


func set_export_preset(preset: String) -> void:
	if export_preset_select == null:
		return
	var normalized: String = EXPORT_CATALOG.normalize_preset(preset)
	for index in range(export_preset_select.item_count):
		if str(export_preset_select.get_item_metadata(index)) == normalized:
			export_preset_select.select(index)
			return


func _refresh_export_preset_items() -> void:
	if export_preset_select == null:
		return
	var selected_preset: String = get_export_preset()
	export_preset_select.clear()
	var presets: Array[Dictionary] = [
		{"label": "EXPORT_PRESET_STANDARD", "value": EXPORT_CATALOG.PRESET_STANDARD},
		{"label": "EXPORT_PRESET_COMPLETE", "value": EXPORT_CATALOG.PRESET_COMPLETE},
		{"label": "EXPORT_PRESET_MINIMAL", "value": EXPORT_CATALOG.PRESET_MINIMAL},
		{"label": "EXPORT_PRESET_DEVELOPMENT", "value": EXPORT_CATALOG.PRESET_DEVELOPMENT},
	]
	for definition in presets:
		export_preset_select.add_item(tr(str(definition["label"])))
		export_preset_select.set_item_metadata(export_preset_select.item_count - 1, str(definition["value"]))
	set_export_preset(selected_preset)


func _set_category_visible(category: String, visible: bool) -> void:
	var panel: PanelContainer = _category_panels.get(category) as PanelContainer
	if panel != null:
		panel.visible = visible


func _apply_planet_type_ui_state() -> void:
	var type_control: OptionButton = _controls.get("planet_type") as OptionButton
	if type_control == null or type_control.selected < 0:
		return
	var planet_type: int = type_control.get_selected_id()
	var no_surface_water: bool = planet_type in [Enum.TYPE_NO_ATMOS, Enum.TYPE_STERILE]
	var gas: bool = planet_type == Enum.TYPE_GAZEUZE
	_set_category_visible("EAU", not no_surface_water and not gas)
	_set_category_visible("NUAGE", not no_surface_water and not gas)
	_set_category_visible("REGION", not gas)
	_set_category_visible("OCEAN", not no_surface_water and not gas)
	_set_category_visible("CRATER", not gas)
	_set_category_visible("EROSION", not gas)


func set_batch_running(running: bool) -> void:
	_batch_running = running
	if running:
		batch_panel.visible = true
	batch_count_spin.editable = not running
	batch_seed_spin.editable = not running
	batch_start_button.disabled = false
	batch_start_button.text = tr("BATCH_CANCEL") if running else tr("BATCH_START")


func set_batch_status(key: String, args: Dictionary = {}) -> void:
	_batch_status_key = key
	_batch_status_args = args.duplicate(true)
	_refresh_batch_status()


func set_batch_progress(completed: int, total: int, seed: int, status: String) -> void:
	var status_key: String = "BATCH_PROGRESS_GENERATING"
	match status:
		"exporting": status_key = "BATCH_PROGRESS_EXPORTING"
		"complete": status_key = "BATCH_PROGRESS_COMPLETE"
		"integrity_fail": status_key = "BATCH_PROGRESS_INTEGRITY_FAIL"
		"failed": status_key = "BATCH_PROGRESS_FAILED"
	set_batch_status(status_key, {
		"completed": completed,
		"total": total,
		"seed": seed,
	})


func set_batch_completed(report: Dictionary) -> void:
	set_batch_status("BATCH_RESULT", {
		"successful": int(report.get("successful", 0)),
		"completed": int(report.get("completed", 0)),
		"report": str(report.get("report_path", "")),
	})


func _refresh_batch_status() -> void:
	if batch_status_label == null:
		return
	batch_status_label.text = tr(_batch_status_key).format(_batch_status_args)


func set_save_planet_enabled(enabled: bool) -> void:
	save_planet_button.disabled = not enabled


func _refresh_parameter_label(key: String) -> void:
	var label := _value_labels.get(key) as Label
	if label == null:
		return
	var definition := PARAMETER_SCHEMA.definition(key)
	if definition.is_empty():
		return
	var tr_key := str(definition.get("label", key))
	var kind := str(definition.get("kind", "slider"))
	if kind in ["text", "option", "spinbox"]:
		label.text = tr(tr_key)
		return
	var value := float(get_value(key))
	var unit := str(definition.get("unit", ""))
	var formatted_value := _format_number(value, float(definition.get("step", 1.0))) + unit
	var translated := tr(tr_key)
	label.text = translated.format({"val": formatted_value})


func _refresh_option_items(key: String) -> void:
	var option := _controls.get(key) as OptionButton
	if option == null:
		return
	var selected_id := option.get_selected_id()
	var options: Array = _option_definitions.get(key, [])
	option.clear()
	for option_definition in options:
		option.add_item(tr(str(option_definition[0])), int(option_definition[1]))
	option.select(_option_index_for_id(option, selected_id))


func _option_index_for_id(option: OptionButton, id: int) -> int:
	for index in range(option.item_count):
		if option.get_item_id(index) == id:
			return index
	return 0


func _format_number(value: float, step: float) -> String:
	if step >= 1.0:
		return str(int(round(value))) if is_equal_approx(value, round(value)) else String.num(value, 2)
	var decimals := clampi(int(ceil(-log(step) / log(10.0))), 1, 6)
	return String.num(value, decimals)
