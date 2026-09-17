extends Node
## SCRAPLAND -- Global event bus, registered as the autoload "GameEvents".
##
## Anything in the world can announce something here and the HUD picks it up,
## without either side holding a reference to the other. That keeps world
## objects (chargers, pickups, salvage piles) completely ignorant of the UI.
##
## Usage from anywhere:
##     GameEvents.notify("+3 Scrap Metal")
##     GameEvents.set_prompt("E — Salvage Barrel")
##     GameEvents.set_objective("Repair the charging station.")
##
## Keep this file tiny. It should only ever declare signals and thin helpers --
## no game logic, or it turns into the god-script we are trying to avoid.

## A transient line of text in the middle of the screen.
signal notification_requested(text: String, color: Color)
## The "E — Salvage" style prompt. An empty string hides it.
signal prompt_changed(text: String)
## The small objective line in the corner.
signal objective_changed(text: String)
## Progress while dismantling something. integrity_ratio counts DOWN from 1.
signal salvage_progress_changed(integrity_ratio: float, label: String)
## Stopped salvaging, either by letting go or by finishing the job.
signal salvage_ended
## Something has made a new blueprint available. Crafting listens for this.
signal recipe_unlock_requested(recipe_id: String)
## A full-screen menu opened. Other menus close themselves so only one is up.
signal menu_opened(menu: Node)
## The menu finished closing (Esc, E, or another menu taking over).
signal menu_closed(menu: Node)
## A container screen opened or closed. The box that owns the inventory listens
## so it can animate its lid, without knowing anything about the UI.
signal container_opened(inventory: Inventory)
signal container_closed(inventory: Inventory)

## Remembered so a HUD that is created after the objective was set can catch up.
## Without this, whether the objective shows would depend on node order.
var current_objective: String = ""


func notify(text: String, color: Color = Color(1, 1, 1)) -> void:
	notification_requested.emit(text, color)


func set_prompt(text: String) -> void:
	prompt_changed.emit(text)


func clear_prompt() -> void:
	prompt_changed.emit("")


func set_objective(text: String) -> void:
	current_objective = text
	objective_changed.emit(text)


func set_salvage_progress(integrity_ratio: float, label: String) -> void:
	salvage_progress_changed.emit(integrity_ratio, label)


func clear_salvage_progress() -> void:
	salvage_ended.emit()


func unlock_recipe(recipe_id: String) -> void:
	recipe_unlock_requested.emit(recipe_id)


## Call this from a menu's open() BEFORE it shows itself, so the menu being
## closed cannot grab the mouse back afterwards.
func announce_menu_opened(menu: Node) -> void:
	menu_opened.emit(menu)


func announce_menu_closed(menu: Node) -> void:
	menu_closed.emit(menu)


func announce_container_opened(inventory: Inventory) -> void:
	container_opened.emit(inventory)


func announce_container_closed(inventory: Inventory) -> void:
	container_closed.emit(inventory)
