extends Resource
class_name SmeltRecipe
## SCRAPLAND -- One furnace conversion. Data, not code: a new smelt is a .tres
## file dropped on the Furnace node.

@export var input_id: String = ""
@export var input_amount: int = 2
@export var output: ItemData
@export var output_amount: int = 1
@export var seconds: float = 6.0


func is_valid() -> bool:
	return not input_id.is_empty() and output != null and input_amount > 0 and output_amount > 0 and seconds > 0.0
