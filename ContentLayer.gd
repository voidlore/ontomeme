extends Resource
class_name ContentLayer

@export var title: String = ""
@export var created: String = ""
@export var modified: String = ""
@export var tags: Array[String] = []
@export var tags_label: String = ""

@export_subgroup("Content")
@export var raw_text: String = ""
@export var structure: Dictionary = {}
