local _G = _G
local math_floor = _G.math.floor
local strconcat = _G.strconcat
local string_format = _G.string.format
local string_gsub = _G.string.gsub
local string_join = _G.string.join
local string_lower = _G.string.lower
local string_sub = _G.string.sub
local string_trim = _G.string.trim

local C_Map_CanSetUserWaypointOnMap = _G.C_Map.CanSetUserWaypointOnMap
local C_Map_GetBestMapForUnit = _G.C_Map.GetBestMapForUnit
local C_Map_GetFallbackWorldMapID = _G.C_Map.GetFallbackWorldMapID
local C_Map_GetMapChildrenInfo = _G.C_Map.GetMapChildrenInfo
local C_Map_GetMapGroupID = _G.C_Map.GetMapGroupID
local C_Map_GetMapGroupMembersInfo = _G.C_Map.GetMapGroupMembersInfo
local C_Map_GetMapInfo = _G.C_Map.GetMapInfo
local C_Map_GetMapPosFromWorldPos = _G.C_Map.GetMapPosFromWorldPos
local C_Map_GetPlayerMapPosition = _G.C_Map.GetPlayerMapPosition
local C_Map_GetUserWaypoint = _G.C_Map.GetUserWaypoint
local C_Map_GetWorldPosFromMapPos = _G.C_Map.GetWorldPosFromMapPos
local C_SuperTrack_SetSuperTrackedUserWaypoint = _G.C_SuperTrack.SetSuperTrackedUserWaypoint
local CreateFrame = _G.CreateFrame
local CreateVector2D = _G.CreateVector2D
local PlaySound = _G.PlaySound

local PLAYER = "player"

local pinpin_frame = CreateFrame("Frame")
pinpin_frame.name = "PinPin"

local saved_variables = {}
local saved_variables_per_character = {}

function pinpin_frame.Print(...)
	print("|CFFFFFF00"..pinpin_frame.name..":|r", ...)
end

-- pinpin_frame.pinpin_frame.Print("Test print for PinPin")

--[[
	-- current_waypoint, nil if no waypoint, otherwise
	-- uiMapID
	-- position (Vector2D)
	-- desc (custom description that appears in tooltips and shares)
	-- string (a user-readable string with map name and coords)
	-- proxy_for (this waypoint isn't actually pinned to the map it appears to be, but rather a parent map, which is stored as proxy_for)
	-- requires_pinpin (for pins to maps that don't allow them and can't be proxied - can't be supertracked or shared with non-PinPin users)
--]]
local current_waypoint

--[[
# Map Names
	-- All maps can be referenced by map ID number
	-- If maps have a name, they can also be referenced by a single unique name:
	-- map name if unique (e.g., "Duskwood")
	-- OR map + floor name if unique (e.g., "Blackrock Mountain - Blackrock Caverns")
	-- OR map(+ floor):parent if possible to construct an unambiguous one (e.g., "Nagrand:Outland")
	-- OR map:ID (e.g., "Dalaran:212")

# Special Rules
	-- 1. if a map+floor name is doubled, like "Orgrimmar - Orgrimmar", and it's unique, then it becomes the canonical "Orgrimmar", and others must disambiguate
	-- this elegantly handles several awkward cases like Orgrimmar and Dalaran: the double-name map is usually the main map the players want (e.g., "Orgrimmar - Orgrimmar" is the normal Orgrimmar, plain "Orgrimmar" is some other Orgrimmar, yet if the player does /way orgrimmar 52 35, they almost certainly want the map for "Orgrimmar - Orgrimmar", not the other random map)

	-- 2. if, for a given name, there is only one map of the most cosmic type (e.g., one map is a zone, others are orphans), it becomes canonical, and others must disambiguate
	-- this handles cases like Ardenweald 1565 and Ardenweald 1603
--]]

local normalized_map_name_to_id = {} -- Case-lowered and spaces normalized for searching, uses ASCII 3 for disambiguation separator internally (since there are map names with colons in them), front-end uses ":" to match other addons
local map_id_to_unique_name = {} -- For displaying unique names; uses ":" as disambiguation separator to match other addons
local map_id_to_data -- resolves and caches additional unenumerated maps that are looked up after initial enumeration
local MAP_SUFFIX_SEP = string.char(3) -- this should be a safe value that is never included in the game's actual map names

-- Begin Process Maps for Name and Data
-- We're going to do this every reload, and it involves most of the heavy lifting, so it is substantially inlined (benchmark: ~30ms)
do
	-- Get the root map by finding the furthest ancestor of the fallback world map
	local root_map_id = C_Map_GetFallbackWorldMapID()
	do
		local parent = C_Map_GetMapInfo(root_map_id).parentMapID
		while parent ~= 0 do
			root_map_id = parent
			parent = C_Map_GetMapInfo(root_map_id).parentMapID
		end
	end

	-- Get the map info for all descendent maps (recursive)
	local map_info = C_Map_GetMapChildrenInfo(root_map_id, nil, true)

	-- Primary goal is now to build map_name_to_id, associating map ID and a unique name with each map's data; and _map_id_to_data, telling PinPin how to handle each map
	local map_name_to_id = {}
	local no_name_maps = {} -- a few maps have no names at all; will have to use ID for display name
	local _map_id_to_data = {}

	local root_map_data = {}
	if not C_Map_CanSetUserWaypointOnMap(root_map_id) then
		root_map_data.requires_pinpin = true -- pins to this map won't display for non-PinPin users
	end
	_map_id_to_data[root_map_id] = root_map_data

	local root_map_name = C_Map_GetMapInfo(root_map_id).name
	if root_map_name and #root_map_name > 0 then
		map_name_to_id[root_map_name] = root_map_id
	else
		no_name_maps[1] = root_map_id
	end

	-- process all maps reachable from the root map
	local test_vector = CreateVector2D(0.5, 0.5) -- dummy vector since we only care about the instanceIDs from C_Map.GetWorldPosFromMapPos
	local dupes = {}
	local dupe_names = {}
	for i = 1, #map_info do
		local map = map_info[i]
		local id = map.mapID

		-- Some maps can't accept pins themselves, but can pin to a "proxy" ancestor
		local proxy
		-- Maps that don't accept pins and lack a proxy won't display for non-PinPin users, so mark as "requires_pinpin = true"
		local requires_pinpin
		if not C_Map_CanSetUserWaypointOnMap(id) then
			-- it can't be pinned directly, so either it can pin to a proxy or it requires PinPin
			local instance_id, world_pos = C_Map_GetWorldPosFromMapPos(id, test_vector)
			if instance_id then
				-- check to see if parent can serve as proxy
				local parent_id = map.parentMapID
				local parent = _map_id_to_data[parent_id]
				if parent.requires_pinpin then
					requires_pinpin = true
				else
					local parent_instance_id = C_Map_GetWorldPosFromMapPos(parent_id, test_vector)
					if instance_id ~= parent_instance_id then
						requires_pinpin = true
					else
						if parent.proxy then
							proxy = parent.proxy
						else
							proxy = parent_id
						end
					end
				end
			else
				requires_pinpin = true
			end
		end

		_map_id_to_data[id] = {proxy = proxy, requires_pinpin = requires_pinpin}

		-- find maps with duplicate names so we can disambiguate them
		local name = map.name
		if name and #name > 0 then
			if map_name_to_id[name] then
				dupes[#dupes + 1] = {name = name, id = id}
				dupe_names[name] = true
			else
				map_name_to_id[name] = id
			end
		else
			no_name_maps[#no_name_maps + 1] = id
		end
	end
	map_info = nil

	for name in next, dupe_names do
		dupes[#dupes + 1] = {name = name, id = map_name_to_id[name]}
		map_name_to_id[name] = nil
	end
	dupe_names = nil

	-- Build the dictionary we're going to be working off of for disambiguation
	local dupes_name_to_ids = {} -- for each ambiguous name, stores an array of ids
	for i = 1, #dupes do
		local dupe = dupes[i]
		local name = dupe.name
		local dupes_entry = dupes_name_to_ids[name]
		if dupes_entry then
			dupes_entry[#dupes_entry + 1] = dupe.id
		else
			dupes_name_to_ids[name] = {dupe.id}
		end
	end
	dupes = nil

	-- If all ambiguous maps have the same instance id and coordinate system, we can just pick one map and use that for the name instead of disambiguating
	-- if two points on both maps project to the same world coords, the maps share the same space
	do
		local test_vector_one = CreateVector2D(0.25, 0.25)
		local test_vector_two = CreateVector2D(0.75, 0.75)
		for name, ids in next, dupes_name_to_ids do
			local pin_to_map
			local native_pin, requires_pinpin, requires_proxy

			local probe_id = ids[1]
			local probe_data = _map_id_to_data[probe_id]
			pin_to_this_map = probe_id
			requires_pinpin = probe_data.requires_pinpin
			requires_proxy = probe_data.proxy ~= nil
			native_pin = not requires_proxy and not requires_pinpin

			local found_unmatched = false
			local instance, world_pos_one = C_Map_GetWorldPosFromMapPos(probe_id, test_vector_one)
			if instance then
				local _, world_pos_two = C_Map_GetWorldPosFromMapPos(probe_id, test_vector_two)
				for i = 2, #ids do
					local test_id = ids[i]
					local test_instance, test_world_pos_one = C_Map_GetWorldPosFromMapPos(test_id, test_vector_one)
					if test_instance ~= instance or test_world_pos_one.x ~= world_pos_one.x or test_world_pos_one.y ~= world_pos_one.y then
						found_unmatched = true
						break
					end
					local _, test_world_pos_two = C_Map_GetWorldPosFromMapPos(test_id, test_vector_two)
					if test_world_pos_two.x ~= world_pos_two.x or test_world_pos_two.y ~= world_pos_two.y then
						found_unmatched = true
						break
					end

					if not native_pin then
						local test_data = _map_id_to_data[test_id]
						if requires_pinpin and not test_data.requires_pinpin then
							pin_to_this_map = test_id
							requires_pinpin = false
							requires_proxy = test_data.proxy ~= nil
							native_pin = not requires_proxy
						elseif not test_data.proxy then
							pin_to_this_map = test_id
							native_pin = true
						end
					end
				end
				if not found_unmatched then
					map_name_to_id[name] = pin_to_this_map
					dupes_name_to_ids[name] = nil
				end
			end
		end
	end

	-- Use floor names to disambiguate
	local new_dupes_name_to_ids = {} -- need to add these to dupes_name_to_ids *after* loop
	for name, ids in next, dupes_name_to_ids do
		local new_ids = {} -- rebuild ids node, fill with anything that doesn't disambiguate
		local double_name_map, double_name_unique
		for i = 1, #ids do
			local got_floor_name = false
			local id = ids[i]
			local map_group = C_Map_GetMapGroupID(id)
			if map_group then
				local floors = C_Map_GetMapGroupMembersInfo(map_group)
				for j = 1, #floors do
					local floor = floors[j]
					if floor.mapID == id then
						local floor_name = floor.name
						got_floor_name = floor_name ~= nil and floor_name ~= ""

						if floor_name == name then
							-- unique double names like "Orgrimmar - Orgrimmar" get promoted to single-name as the true "Orgrimmar"
							if double_name_map then
								if double_name_unique then
									double_name_unique = false
									local name_with_floor = string_join(" - ", name, floor_name)
									local existing_new_dupes_entry = new_dupes_name_to_ids[name_with_floor]
									if existing_new_dupes_entry then
										existing_new_dupes_entry[#existing_new_dupes_entry + 1] = double_name_map
									else
										new_dupes_name_to_ids[name_with_floor] = {double_name_map}
									end
								end
								local name_with_floor = string_join(" - ", name, floor_name)
								local existing_new_dupes_entry = new_dupes_name_to_ids[name_with_floor]
								if existing_new_dupes_entry then
									existing_new_dupes_entry[#existing_new_dupes_entry + 1] = id
								else
									new_dupes_name_to_ids[name_with_floor] = {id}
								end
							else
								double_name_map = id
								double_name_unique = true
							end
						else
							local name_with_floor = string_join(" - ", name, floor_name)
							local existing_new_dupes_entry = new_dupes_name_to_ids[name_with_floor]
							if existing_new_dupes_entry then
								existing_new_dupes_entry[#existing_new_dupes_entry + 1] = id
							else
								new_dupes_name_to_ids[name_with_floor] = {id}
							end
						end
						break
					end
				end
			end
			if not got_floor_name then
				new_ids[#new_ids + 1] = id
			end
		end

		-- Promote unique double name to canonical name ("Orgrimmar - Orgrimmar" becomes canonical "Orgrimmar")
		if double_name_unique then
			map_name_to_id[name] = double_name_map
		end

		local num_new_ids = #new_ids
		if num_new_ids == 1 and not double_name_unique then
			-- map was retroactively disambiguated by all other ambiguous maps gaining floor names
			map_name_to_id[name] = new_ids[1]
			dupes_name_to_ids[name] = nil
		elseif num_new_ids > 0 then
			dupes_name_to_ids[name] = new_ids
		else
			dupes_name_to_ids[name] = nil
		end
	end
	for name, ids in next, new_dupes_name_to_ids do
		if #ids == 1 then
			map_name_to_id[name] = ids[1]
		else
			dupes_name_to_ids[name] = ids
		end
	end
	new_dupes_name_to_ids = nil

	-- finish disambiguation
	for name, ids in next, dupes_name_to_ids do
		-- see if there's a singleton with the smallest map_type that we can promote to the canonical reference for this name
		if not map_name_to_id[name] then
			-- there isn't already a promoted double-name, so we can try to promote based on map_type
			local map_type_to_ids = {}
			local smallest_map_type = math.huge -- smallest map_type is the most cosmic map type
			for i = 1, #ids do
				local id = ids[i]
				local map_type = C_Map_GetMapInfo(id).mapType
				if map_type < smallest_map_type then
					smallest_map_type = map_type
				end
				local existing_entry = map_type_to_ids[map_type]
				if existing_entry then
					existing_entry[#existing_entry + 1] = id
				else
					map_type_to_ids[map_type] = {id}
				end
			end

			local new_ids = {}
			for map_type, ids in next, map_type_to_ids do
				if #ids == 1 and map_type == smallest_map_type then
					map_name_to_id[name] = ids[1]
				else
					for i = 1, #ids do
						new_ids[#new_ids + 1] = ids[i]
					end
				end
			end
			ids = new_ids
		end

		-- Try using parent maps to disambiguate (e.g., Nagrand:Outland)
		local parent_name_to_ids = {}
		for i = 1, #ids do
			local id = ids[i]
			local parent = C_Map_GetMapInfo(id).parentMapID
			local parent_name = C_Map_GetMapInfo(parent).name
			if parent_name and #parent_name > 0 then
				local existing_entry = parent_name_to_ids[parent_name]
				if existing_entry then
					existing_entry[#existing_entry + 1] = id
				else
					parent_name_to_ids[parent_name] = {id}
				end
			else
				map_name_to_id[string_join(MAP_SUFFIX_SEP, name, id)] = id
			end
		end

		for parent_name, ids in next, parent_name_to_ids do
			if #ids == 1 then
				local id = ids[1]
				local parent = C_Map_GetMapInfo(id).parentMapID
				local promoted_map = map_name_to_id[name] -- check if we've already promoted something to become canonical for this name
				if promoted_map and C_Map_GetMapInfo(promoted_map).parentMapID == parent then
					-- map shares parent map and name with a promoted map
					map_name_to_id[string_join(MAP_SUFFIX_SEP, name, id)] = id
				else
					map_name_to_id[string_join(MAP_SUFFIX_SEP, name, parent_name)] = id
				end
			else
				for i = 1, #ids do
					local id = ids[i]
					map_name_to_id[string_join(MAP_SUFFIX_SEP, name, id)] = id
				end
			end
		end
	end

	-- Build outputs for searching and displaying
	for name, id in next, map_name_to_id do
		normalized_map_name_to_id[string_lower(string_gsub(name, "%s+", " "))] = id
		map_id_to_unique_name[id] = string_gsub(name, MAP_SUFFIX_SEP, ":", 1)
	end

	-- Maps with no name use map id instead
	for i = 1, #no_name_maps do
		local id = no_name_maps[i]
		map_id_to_unique_name[id] = tostring(id)
	end

	-- For map_id_to_data lookups. Also resolves lookups of unenumerated maps and caches their value
	map_id_to_data = function (id)
		local map_data = _map_id_to_data[id]
		if map_data then
			return map_data
		end

		if not C_Map_GetMapInfo(id) then
			pinpin_frame.Print(tostring(id) + " is not a valid map.")
			return
		end

		-- it's a map we haven't enumerated
		_map_id_to_data[id] = {id = id}
		local data = _map_id_to_data
		if not C_Map_CanSetUserWaypointOnMap(id) then
			local instance_id = C_Map_GetWorldPosFromMapPos(id, test_vector)
			if not instance_id then
				data.requires_pinpin = true
			else
				local parent_id = C_Map_GetMapInfo(id).parentMapID
				while parent_id ~= 0 do
					local parent_data = _map_id_to_data[parent_id]
					if parent_data and parent_data.requires_pinpin then
						data.requires_pinpin = true
						break
					end
					local parent_instance_id = C_Map_GetWorldPosFromMapPos(parent_id, test_vector)
					if instance_id ~= parent_instance_id then
						data.requires_pinpin = true
						break
					elseif parent_data then
						if parent_data.proxy then
							data.proxy = parent_data.proxy
						else
							data.proxy = parent_id
						end
						break
					elseif C_Map_CanSetUserWaypointOnMap(parent_id) then
						data.proxy = parent_id
						break
					else
						parent_id = C_Map_GetMapInfo(parent_id).parentMapID
					end
				end
			end
		end
		return data
	end
end
-- End Process Maps for Name and Data

-- handle = do_after_combat(function, args...) to call protected functions once combat ends
-- do_after_combat_preempt(handle) to cancel
local do_after_combat, do_after_combat_preempt, on_player_regen_enabled
do
	local queue = {} -- stores a queue of handles
	local funcs = {} -- maps handles to function calls

	function on_player_regen_enabled() -- PLAYER_REGEN_ENABLED event detects end of combat
		for i = 1, #queue do
			local handle = queue[i]
			local funcs_entry = funcs[handle]
			if funcs_entry then
				funcs_entry.func(unpack(funcs_entry.args))
			end
		end
		queue = {}
		funcs = {}
	end

	function do_after_combat(func, ...)
		local handle = {}
		queue[#queue + 1] = handle
		funcs[handle] = {func = func, args = {...}}
		return handle
	end

	function do_after_combat_preempt(handle)
		if handle then
			funcs[handle] = nil
		end
	end
end

local function unrotate_minimap_coords(rotated_x, rotated_y)
	local theta = GetPlayerFacing()
	local sin_theta = math.sin(theta)
	local cos_theta = math.cos(theta)
	local unrotated_x = rotated_x * cos_theta - rotated_y * sin_theta
	local unrotated_y = rotated_x * sin_theta + rotated_y * cos_theta
	return unrotated_x, unrotated_y
end

-- Used, e.g., to play pin sounds if the player can see the pin on their map
local function is_pin_visible_on_open_map()
	if not WorldMapFrame:IsVisible() or not current_waypoint then
		return false
	end

	local open_map = WorldMapFrame:GetMapID()
	local position_in_open_map = C_Map.GetUserWaypointPositionForMap(open_map)
	local x, y
	if position_in_open_map then
		x, y = position_in_open_map:GetXY()
	else
		-- This is a non-native pin, so we need to test it ourselves
		local test_vector = CreateVector2D(0.5, 0.5)
		local open_map_instance = C_Map_GetWorldPosFromMapPos(open_map, test_vector)
		local current_waypoint_instance = C_Map_GetWorldPosFromMapPos(current_waypoint.uiMapID, test_vector)
		if open_map_instance ~= current_waypoint_instance then
			return false
		end
		x, y = current_waypoint.position.x, current_waypoint.position.y
	end
	return x >= 0 and x <= 1 and y >= 0 and y <=1
end

local waypoint_history_add, waypoint_history_last, waypoint_history_save, waypoint_history_restore
do
	-- history is an array with a wrap-around index
	local HISTORY_SIZE = 100
	local history = {}
	local index = 0

	function waypoint_history_add(waypoint)
		index = index % HISTORY_SIZE + 1
		history[index] = waypoint
	end

	function waypoint_history_last() -- Not being used?
		if index ~= 0 then
			return history[index]
		end
	end

	-- Aligns history to an index of 1 for saving
	function waypoint_history_save()
		if index ~= 0 then
			if #history < HISTORY_SIZE then
				return history
			else
				local waypoints = {}
				for i = 0, HISTORY_SIZE - 1 do
					local read_index = (index + i) % HISTORY_SIZE + 1
					waypoints[#waypoints + 1] = history[read_index]
				end
				return waypoints
			end
		end
	end

	function waypoint_history_restore(waypoints)
		if waypoints then
			history = waypoints
			index = #waypoints
		end
	end
end

-- e.g., given 1.31, 1.2, returns 2 because .31 goes to 2 decimal places (and that's more places than .2)
-- so we can, e.g., print "1.31, 1.20" rather than "1.31, 1.2"
local function longest_fractional_part_length(...)
	local nums = {...}
	local places = 0
	for _, num in ipairs(nums) do
		local test_places = #tostring(num % 1) - 2 -- the -2 is for the "0."
		if test_places > places then
			places = test_places
		end
	end
	return places
end

local function get_waypoint_string_subparts(waypoint)
	local MAX_DECIMAL_PLACES = 2

	local x = waypoint.position.x * 100
	local y = waypoint.position.y * 100
	local places = longest_fractional_part_length(x, y)
	places = min(places, MAX_DECIMAL_PLACES)
	local format_string = strconcat("%.", places, "f")
	local map_name
	if waypoint.proxy_for then
		map_name = map_id_to_unique_name[waypoint.proxy_for]
	else
		map_name = map_id_to_unique_name[waypoint.uiMapID]
	end
	return map_name, string_format(format_string, x), string_format(format_string, y)
end

local function get_waypoint_string(waypoint)
	local display_name, display_x, display_y = get_waypoint_string_subparts(current_waypoint)
	return strconcat(display_name, " (", display_x, ", ", display_y, ")")
end

local function set_current_waypoint_string()
	current_waypoint.string = get_waypoint_string(current_waypoint)
end

local refresh_waypoint_location_data_provider -- implemented in hooks

local function clear_waypoint()
	if current_waypoint then
		if is_pin_visible_on_open_map() then
			PlaySound(SOUNDKIT.UI_MAP_WAYPOINT_REMOVE, nil, SOUNDKIT_ALLOW_DUPLICATES)
		end
		C_Map.ClearUserWaypoint()
		current_waypoint = nil
		refresh_waypoint_location_data_provider()
	end
end

local function set_waypoint(map, position, desc)
	local map_data = map_id_to_data(map)

	local old_pin_visible = is_pin_visible_on_open_map() -- there was a pre-existing pin that we're replacing

	if map_data.requires_pinpin then
		C_Map.ClearUserWaypoint()
		current_waypoint = {
			uiMapID = map,
			position = position,
			requires_pinpin = true
		}
		refresh_waypoint_location_data_provider()
		C_SuperTrack_SetSuperTrackedUserWaypoint(false) -- no point supertracking requires_pinpin pins
	else
		local proxy = map_data.proxy
		local proxy_for
		if proxy then
			local instance, world_pos = C_Map_GetWorldPosFromMapPos(map, position)
			position = select(2, C_Map_GetMapPosFromWorldPos(instance, world_pos, proxy))
			proxy_for = map -- track this in case user wants to share a proxied waypoint with a non-PinPin user
			map = proxy
		end
		local map_point = UiMapPoint.CreateFromVector2D(map, position)
		C_Map.SetUserWaypoint(map_point)
		current_waypoint = C_Map_GetUserWaypoint()
		current_waypoint.proxy_for = proxy_for

		if saved_variables.semi_automatic_supertrack_pins and (saved_variables.automatic_supertrack_pins or not C_SuperTrack.IsSuperTrackingAnything()) then
			C_SuperTrack_SetSuperTrackedUserWaypoint(true)
		end
	end

	set_current_waypoint_string()
	if desc then
		current_waypoint.desc = string_trim(desc)
	end

	waypoint_history_add(current_waypoint)

	if is_pin_visible_on_open_map() then
		PlaySound(SOUNDKIT.UI_MAP_WAYPOINT_CLICK_TO_PLACE, nil, SOUNDKIT_ALLOW_DUPLICATES)
	elseif old_pin_visible then
		PlaySound(SOUNDKIT.UI_MAP_WAYPOINT_REMOVE, nil, SOUNDKIT_ALLOW_DUPLICATES)
	end
end

-- Parse map name
-- returns map ID if it found exact match, otherwise prints potential matches and returns nil
local function parse_map_name(input)
	local MAX_AMBIGUOUS_MAP_NAMES_TO_SHOW = 7

	local normed_input = string_lower(input)
	local matching_map_ids = {}
	local exact_match = normalized_map_name_to_id[normed_input]
	if exact_match then
		return exact_match
	else
		-- partial matching
		-- first try only prefixes (don't match "Greymane Manor:Ruins of Gilneas" on the input "Gilneas")
		for db_name, db_map_id in pairs(normalized_map_name_to_id) do
			local db_name_sep = strfind(db_name, MAP_SUFFIX_SEP, 1, true)
			local prefix
			if db_name_sep then
				prefix = string_sub(db_name, 1, db_name_sep - 1)
			else
				prefix = db_name
			end

			if strfind(prefix, normed_input, 1, true) then
				matching_map_ids[#matching_map_ids + 1] = db_map_id
			end
		end
		-- try suffixes too
		if #matching_map_ids == 0 then
			for db_name, db_map_id in pairs(normalized_map_name_to_id) do
				if strfind(string_gsub(db_name, MAP_SUFFIX_SEP, ":", 1), normed_input, 1, true) then -- front-end separators are ":"
					matching_map_ids[#matching_map_ids + 1] = db_map_id
				end
			end
		end
	end

	-- Handle bad/ambiguous map inputs
	if #matching_map_ids > 1 then
		if #matching_map_ids > MAX_AMBIGUOUS_MAP_NAMES_TO_SHOW then
			pinpin_frame.Print(#matching_map_ids .. " possible matches for zone \"" .. input .. "\". Top results:")
		else
			pinpin_frame.Print(#matching_map_ids .. " possible matches for zone \"" .. input .. "\". Did you mean:")
		end

		local matching_map_names = {}
		for _, id in ipairs(matching_map_ids) do
			matching_map_names[#matching_map_names + 1] = map_id_to_unique_name[id]
		end
		sort(matching_map_names,
		function (a, b)
			return #a < #b
		end
		)
		for i = 1, min(MAX_AMBIGUOUS_MAP_NAMES_TO_SHOW, #matching_map_ids) do
			pinpin_frame.Print(matching_map_names[i])
		end
	elseif #matching_map_ids == 0 then
		-- do a fuzzy search and show the best guesses for the map
		pinpin_frame.Print("Couldn't find zone \"" .. input .. "\". Did you mean:")
		local fuzzy_matching_map_names = {}
		local input_length = #normed_input
		for name, id in pairs(normalized_map_name_to_id) do
			local name_length = #name
			local length_diff = name_length - input_length
			local edit_distance = CalculateStringEditDistance(normed_input, string_gsub(name, MAP_SUFFIX_SEP, ":", 1))
			if length_diff > 0 then
				edit_distance = edit_distance - length_diff -- remove penalty for insertions
			end
			if edit_distance < input_length then
				fuzzy_matching_map_names[#fuzzy_matching_map_names + 1] = {id, edit_distance, name_length}
			end
		end

		-- Sort by edit distance
		sort(fuzzy_matching_map_names,
		function (a,b)
			if a[2] < b[2] then
				return true
			elseif a[2] > b[2] then
				return false
			else
				-- if equal edit distance, then favor the shorter one
				return a[3] < b[3]
			end
		end
		)

		for i = 1, min(#fuzzy_matching_map_names, MAX_AMBIGUOUS_MAP_NAMES_TO_SHOW) do
			local id = fuzzy_matching_map_names[i][1]
			pinpin_frame.Print(map_id_to_unique_name[id])
		end
	end
end

local function waypoint_command_syntax()
	local slash_prefix = saved_variables.prefix
	pinpin_frame.Print("Syntax:\n/" .. slash_prefix .. " [map name|map number] x y [description]")
	pinpin_frame.Print("Examples:\n/" .. slash_prefix .. " Orgrimmar 52.5 12.3\n/"
	.. slash_prefix .. " 85 52.5 12.3\n/"
	.. slash_prefix .. " Ogrimmar - Cleft of Shadows 65.23 7\n/"
	.. slash_prefix .. " Nagrand:Outland 84 61")
end

-- Parses syntax for commands like /way and /wayl: [map name|map number] x y [description]
-- returns uiMapPoint and desc if unambiguous, otherwise nil
local function parse_waypoint_command(msg)
	if #msg == 0 then
		pinpin_frame.Print("For help: /" .. saved_variables.prefix .. "help")
		waypoint_command_syntax()
		return
	end

	-- Strip comma or period-separated coords ("8, 15" -> "8 15")
	msg = msg:gsub("(%d)[.,] (%d)", "%1 %2", 1)

	-- Deal with locale differences in decimal separators
	local wrong_sep
	local right_sep
	if tonumber("1.1") == nil then -- this tonumber will return nil if locale doesn't use "." as decimal separator
		right_sep = ","
		wrong_sep = "."
	else
		right_sep = "."
		wrong_sep = ","
	end
	local wrong_sep_pattern = strconcat("(%d)", wrong_sep, "(%d)")
	local right_sep_pattern = strconcat("%1", right_sep, "%2")
	msg = msg:gsub(wrong_sep_pattern, right_sep_pattern, 1)

	local tokens = {}
	for token in gmatch(msg, "%S+") do
		tokens[#tokens + 1] = token
	end

	-- first number could be map number or the x coord
	local first_number_pos
	local first_number
	for i, token in ipairs(tokens) do
		local to_number = tonumber(token)
		if to_number then
			first_number_pos = i
			first_number = to_number
			break
		end
	end

	if not first_number then
		waypoint_command_syntax()
		return
	end

	local second_number = tonumber(tokens[first_number_pos + 1]) -- second_number is x or y
	if not second_number or second_number < 0 or second_number > 100 then
		waypoint_command_syntax()
		return
	end

	if first_number_pos ~= 1 then
		-- user provided (map name, x, y)

		if first_number < 0 or first_number > 100 then -- first number must be x coordinate
			waypoint_command_syntax()
			return
		end

		local name_tokens = {}
		for i = 1, first_number_pos - 1 do
			name_tokens[#name_tokens + 1] = tokens[i]
		end
		local input_name = string_join(" ", unpack(name_tokens))

		local exact_match = parse_map_name(input_name)
		if not exact_match then
			return
		end

		local desc_tokens = {}
		for i = first_number_pos + 2, #tokens do
			desc_tokens[#desc_tokens + 1] = tokens[i]
		end

		return {uiMapID = exact_match, position = CreateVector2D(first_number / 100, second_number / 100), desc = strconcat(unpack(desc_tokens))}
	else
		-- user either provided (numerical map, x, y) or just (x, y)
		local third_number = tonumber(tokens[first_number_pos + 2])
		if third_number and third_number >= 0 and third_number <= 100 then
			-- user entered (numerical map, x, y)
			local desc_tokens = {}
			for i = first_number_pos + 3, #tokens do
				desc_tokens[#desc_tokens + 1] = tokens[i]
			end
			local desc
			if #desc_tokens > 0 then
				desc = strconcat(unpack(desc_tokens))
			end
			return {uiMapID = first_number, position = CreateVector2D(second_number / 100, third_number / 100), desc = desc}
		elseif first_number >= 0 and first_number <= 100 then -- first number must be x coordinate
			-- user entered just (x, y)
			local desc_tokens = {}
			for i = first_number_pos + 2, #tokens do
				desc_tokens[#desc_tokens + 1] = tokens[i]
			end
			local desc
			if #desc_tokens > 0 then
				desc = strconcat(unpack(desc_tokens))
			end
			-- if their map is open, pin to the zone they're open to
			if WorldMapFrame:IsVisible() then
				return {uiMapID = WorldMapFrame:GetMapID(), position = CreateVector2D(first_number / 100, second_number / 100), desc = desc}
			end
			-- if map is closed, pin in the zone the player is currently in
			return {uiMapID = C_Map_GetBestMapForUnit(PLAYER), position = CreateVector2D(first_number / 100, second_number / 100), desc = desc}
		end
	end
end

-- paste_in_chat(text)
-- Hook OnEnterPressed then paste into chat (for commands that fill text into edit box, letting the user edit and send with Enter normally)
local paste_in_chat
do
	local keeping_focus = false
	local paste

	hooksecurefunc("ChatEdit_OnEnterPressed", function ()
		if keeping_focus then
			local edit_box = LAST_ACTIVE_CHAT_EDIT_BOX
			if C_CVar.GetCVar("chatStyle") == "classic" then
				edit_box:Show()
			end
			edit_box:SetFocus()
			edit_box:SetText(paste)
			keeping_focus = false
		end
	end)

	function paste_in_chat(text)
		paste = text
		keeping_focus = true
	end
end

-- Clear active pin when user comes within user-defined distance
hooksecurefunc(SuperTrackedFrame, "UpdateDistanceText", function ()
	if saved_variables.automatic_clear then
		local distance = C_Navigation.GetDistance()
		if distance > 0 and distance <= saved_variables.clear_distance then
			clear_waypoint()
		end
	end
end)

-- More useful Map Pin tooltips
do
	local function update_waypoint_tooltip()
		GameTooltip_SetTitle(GameTooltip, current_waypoint.desc or "Map Pin", NORMAL_FONT_COLOR)
		local distance = C_Navigation.GetDistance()
		if distance > 0 then
			GameTooltip_AddBlankLineToTooltip(GameTooltip)
			GameTooltip_AddColoredLine(GameTooltip, string_format("%d |4yard:yards away", math_floor(C_Navigation.GetDistance())), WHITE_FONT_COLOR)
		end
		GameTooltip_AddColoredLine(GameTooltip, current_waypoint.string, LIGHTGRAY_FONT_COLOR)
		GameTooltip_AddBlankLineToTooltip(GameTooltip)
		GameTooltip_AddInstructionLine(GameTooltip, "<Shift-Click to share pin in chat>")
		GameTooltip_AddInstructionLine(GameTooltip, MAP_PIN_REMOVE)
		GameTooltip:Show()
	end

	local in_waypoint_tooltip = false

	hooksecurefunc(WaypointLocationPinMixin, "OnMouseEnter", function ()
		in_waypoint_tooltip = true
		if saved_variables.better_tooltips then
			update_waypoint_tooltip()
		end
	end)

	hooksecurefunc(WaypointLocationPinMixin, "OnMouseLeave", function ()
		in_waypoint_tooltip = false
	end)

	GameTooltip:HookScript("OnUpdate", function ()
		if in_waypoint_tooltip and saved_variables.better_tooltips then
			if current_waypoint then
				update_waypoint_tooltip()
			else
				-- Waypoint was cleared while the cursor was inside it
				in_waypoint_tooltip = false
			end
		end
	end)
end

-- Custom min and max viewable distance for pins
do
	local old_GetTargetAlphaBaseValue = SuperTrackedFrame.GetTargetAlphaBaseValue
	function SuperTrackedFrame:GetTargetAlphaBaseValue()
		local alpha = old_GetTargetAlphaBaseValue(self)
		local distance = C_Navigation.GetDistance()
		local unlimited = saved_variables.unlimited_pin_distance
		local min_distance = saved_variables.min_pin_distance
		local max_distance = saved_variables.max_pin_distance
		if not unlimited and distance > max_distance then
			alpha = 0
		elseif distance < min_distance then
			alpha = 0
		elseif alpha == 0 then
			if distance > 500 then
				if unlimited or distance <= max_distance then
					alpha = 0.6
				end
			else
				if distance >= min_distance then
					alpha = 1
				end
			end
		end
		return alpha
	end
end

-- Hooks for Blizzard data providers and overlays
do
	-- Data providers are unlabeled, so we have to find it
	local waypoint_location_data_provider
	for data_provider in pairs(WorldMapFrame.dataProviders) do
		if data_provider.CanPlacePin then -- CanPlacePin is our shibboleth for this particular data provider
			waypoint_location_data_provider = data_provider
			break
		end
	end
	if not waypoint_location_data_provider then
		error("Couldn't find the map pin data provider.")
	end

	-- Overlay frames are unlabeled, so we have to find it
	local waypoint_button_frame
	local world_map_frame_children = {WorldMapFrame:GetChildren()}
	for i = 1, #world_map_frame_children do
		local child = world_map_frame_children[i]
		if child.SetActive then
			waypoint_button_frame = child
			break
		end
	end
	if not waypoint_button_frame then
		error("Couldn't find the map overlay with the map pin button.")
	end

	-- CLICK HANDLERS
	-- Blizzard uses two separate click handlers: one on the pin itself, and one on the data provider that checks if the cursor is in the pin
	-- the pin click handler deals with creating chat hyperlinks and toggling supertracking
	-- the data provider click handler deals with adding and removing pins

	hooksecurefunc(WaypointLocationPinMixin, "OnMouseClickAction", function ()
		if current_waypoint.requires_pinpin then
			if IsModifiedClick("CHATLINK") then
				-- trying to create a chat link
				pinpin_frame.Print("Pinning to that map requires PinPin. Are you sure you want to share the pin?")
				local x = math_floor(current_waypoint.position.x * 10000)
				local y = math_floor(current_waypoint.position.y * 10000)
				local to_paste = strconcat("|cffffff00|Hworldmap:", current_waypoint.uiMapID, ":", x, ":", y, "|h[", MAP_PIN_HYPERLINK, "]|h|r")
				to_paste = string_join(" ", current_waypoint.string, to_paste)
				local desc = current_waypoint.desc
				if desc then
					to_paste = string_join(" ", to_paste, desc)
				end
				to_paste = to_paste .. " (requires PinPin)"
				ChatEdit_InsertLink(to_paste)
				PlaySound(SOUNDKIT.UI_MAP_WAYPOINT_CHAT_SHARE, nil, SOUNDKIT_ALLOW_DUPLICATES)
			elseif mouse_button == "LeftButton" then
				-- trying to supertrack
				pinpin_frame.Print("This map pin is PinPin-only and can't be supertracked.")
			end
		else
			-- better text for linking regular waypoints
			if IsModifiedClick("CHATLINK") then
				local edit_box = LAST_ACTIVE_CHAT_EDIT_BOX
				local text = edit_box:GetText()
				if text == "" then
					return
				end

				local link_start_probe = "|cffffff00|Hworldmap:"
				local link_start, link_start_last_char = strfind(text, link_start_probe, 1, true)
				if not link_start then
					return
				end
				local link_end_probe = strconcat("|h[", MAP_PIN_HYPERLINK, "]|h|r")
				local _, link_end = strfind(text, link_end_probe, link_start_last_char, true)

				local prefix = string_trim(string_sub(text, 1, link_start - 1))
				local hyperlink = string_sub(text, link_start, link_end)
				local suffix = string_trim(string_sub(text, link_end + 1))
				local desc = current_waypoint.desc

				to_join = {}
				if prefix then
					to_join[#to_join + 1] = prefix
				end
				to_join[#to_join + 1] = current_waypoint.string
				to_join[#to_join + 1] = hyperlink
				if desc then
					to_join[#to_join + 1] = desc
				end
				if suffix then
					to_join[#to_join + 1] = suffix
				end
				edit_box:SetText(table.concat(to_join, " "))
			end
		end
	end)

	-- Hook the add/remove waypoint click handler so we can add/remove PinPin-only pins with it too
	hooksecurefunc(waypoint_location_data_provider, "HandleClick", function (self)
		local map = self:GetMap()
		local map_id = map:GetMapID()
		if C_Map_CanSetUserWaypointOnMap(map_id) then
			-- we're dealing with native pins
			if C_Map_GetUserWaypoint() then
				current_waypoint = C_Map_GetUserWaypoint()
				set_current_waypoint_string()

				if saved_variables.semi_automatic_supertrack_pins and (saved_variables.automatic_supertrack_pins or not C_SuperTrack.IsSuperTrackingAnything()) then
					C_SuperTrack_SetSuperTrackedUserWaypoint(true)
				end
			else
				current_waypoint = nil
			end
		else
			-- we're dealing with a map that requires a proxy or requires_pinpin
			if self.pin and self.pin:IsMouseOver() then
				-- we're removing a pin
				clear_waypoint()
			elseif current_waypoint and current_waypoint.proxy_for and not C_Map_GetUserWaypoint() then
				-- we're deleting a pin that used a proxy
				current_waypoint = nil
				return
			else
				-- we're adding a proxied pin or requires_pinpin pin
				UIErrorsFrame:Clear()
				UIErrorsFrame:Show()
				local scroll_container = map.ScrollContainer
				local cursor_x, cursor_y = scroll_container:NormalizeUIPosition(scroll_container:GetCursorPosition())
				set_waypoint(map_id, CreateVector2D(cursor_x, cursor_y))
			end
		end
		waypoint_button_frame:SetActive(false)
	end)

	-- Display requires_pinpin pins on instance maps
	hooksecurefunc(waypoint_location_data_provider, "RefreshAllData", function (self)
		if not current_waypoint or not current_waypoint.requires_pinpin then
			return
		end

		local pin_pos
		local open_map = WorldMapFrame:GetMapID()
		local current_waypoint_map = current_waypoint.uiMapID
		local current_waypoint_pos = current_waypoint.position
		local x, y
		if current_waypoint_map == open_map then
			pin_pos = current_waypoint_pos
			x, y = pin_pos.x, pin_pos.y
		else
			-- see if the pin should show up on this map too
			local current_waypoint_instance, world_pos = C_Map_GetWorldPosFromMapPos(current_waypoint_map, current_waypoint_pos)
			local open_map_instance = C_Map_GetWorldPosFromMapPos(open_map, current_waypoint_pos) -- just reuse position (we only care about getting instance ID anyway)
			if current_waypoint_instance ~= open_map_instance then
				return
			end
			local _, pin_pos = C_Map_GetMapPosFromWorldPos(current_waypoint_instance, world_pos, open_map)
			x, y = pin_pos.x, pin_pos.y
			if x < 0 or x > 1 or y < 0 or y > 1 then
				return
			end
		end

		self.pin = self:GetMap():AcquirePin("WaypointLocationPinTemplate");
		self.pin:SetPosition(pin_pos.x, pin_pos.y)
	end)

	-- Must be called after removing a map pin to get it to actually hide
	refresh_waypoint_location_data_provider = function ()
		waypoint_location_data_provider:RefreshAllData()
	end

	-- Keep the pin-placement button on the map UI enabled for all maps so we can place PinPin-only pins with it too
	hooksecurefunc(waypoint_button_frame, "Refresh", function (self)
		self:Enable()
		self:DesaturateHierarchy(0)
	end)

	-- Display a more appropriate tooltip for the pin-placement button for PinPin-only maps
	waypoint_button_frame:HookScript("OnEnter", function (self)
		GameTooltip:ClearLines()
		GameTooltip_AddNormalLine(GameTooltip, MAP_PIN_TOOLTIP)
		GameTooltip_AddBlankLineToTooltip(GameTooltip)
		GameTooltip_AddInstructionLine(GameTooltip, MAP_PIN_TOOLTIP_INSTRUCTIONS)
		GameTooltip:Show()
	end)
end

-- Handle clicks to chat waypoint links
hooksecurefunc("ChatFrame_OnHyperlinkShow", function (self, link, text)
	if string_sub(link, 1, 8) == "worldmap" then
		local map_point = C_Map.GetUserWaypointFromHyperlink(link)
		if not map_point then
			return
		end

		if C_Map_CanSetUserWaypointOnMap(map_point.uiMapID) then
			-- we're dealing with native pins
			current_waypoint = C_Map_GetUserWaypoint()
			set_current_waypoint_string()

			-- Blizzard didn't bother to add the sound for this
			if is_pin_visible_on_open_map() then
				PlaySound(SOUNDKIT.UI_MAP_WAYPOINT_CLICK_TO_PLACE, nil, SOUNDKIT_ALLOW_DUPLICATES)
			end

			if saved_variables.semi_automatic_supertrack_pins and (saved_variables.automatic_supertrack_pins or not C_SuperTrack.IsSuperTrackingAnything()) then
				C_SuperTrack_SetSuperTrackedUserWaypoint(true)
			end
		else
			-- we're pinning to a map that requires a proxy or requires_pinpin
			set_waypoint(map_point.uiMapID, map_point.position)
		end

		-- Try to get a desc from the right or left of the hyperlink in chat
		-- Search through the chat frame for the message
		for i = self:GetNumMessages(), 1, -1 do
			local chat_text = self:GetMessageInfo(i)
			local link_start, link_end = strfind(chat_text, text, 1, true)
			if link_start then
				-- First see if there's any text we can use to the right of the hyperlink
				local right = string_trim(string_sub(chat_text, link_end + 1))
				if right ~= "" then
					current_waypoint.desc = right
				else
					-- No text to the right, so check for text to the left
					local left = string_sub(chat_text, 1, link_start - 1)
					-- left text includes time stamps, character names, etc. The first hyperlink should be the speaker.
					local _, left_junk_end = strfind(left, "^.-|H.+|h")
					if left_junk_end then
						left = string_sub(left, left_junk_end + 1)
					end
					--remaining junk should end with a colon (e.g., " says: ")
					local colon_pos = strfind(left, ":", 1, true)
					if colon_pos then
						left = string_sub(left, colon_pos + 1)
					end
					left = string_trim(left)
					if left ~= "" then
						current_waypoint.desc = left
					end
				end
				break
			end
		end
	end
end)

local waym
do
	local open_map_frame_to_map_id
	local open_map_frame_to_waypoint = false
	local open_map_frame_do_after_combat_handle

	-- display map potentially delayed due to combat
	WorldMapFrame:HookScript("OnShow", function (self)
		if open_map_frame_to_map_id then
			WorldMapFrame:SetMapID(open_map_frame_to_map_id)
			open_map_frame_to_map_id = nil
			do_after_combat_preempt(open_map_frame_do_after_combat_handle)
		elseif open_map_frame_to_waypoint then
			if current_waypoint then
				WorldMapFrame:SetMapID(current_waypoint.uiMapID)
			else
				pinpin_frame.Print("There aren't any pins on the map.")
			end
			open_map_frame_to_waypoint = false
			do_after_combat_preempt(open_map_frame_do_after_combat_handle)
		end
	end)

	-- if provided with a map name or ID, opens to that map
	-- otherwise, open map to current waypoint
	waym = function (msg)
		local map

		local specified_a_map = msg ~= ""
		if specified_a_map then
			local map_num = tonumber(msg)
			if map_num and map_num == math_floor(map_num) then
				map = map_num
			else
				local msg_norm_spaces = string_gsub(msg, "%s", " ")
				local exact_match = parse_map_name(msg_norm_spaces)
				if exact_match then
					map = exact_match
				else
					return
				end
			end
		else
			if current_waypoint then
				map = current_waypoint.uiMapID
			else
				pinpin_frame.Print("There aren't any pins on the map.")
				return
			end
		end

		if WorldMapFrame:IsVisible() then
			WorldMapFrame:SetMapID(map)
			return
		end

		-- set upvalues for WorldMapFrame:Show()
		open_map_frame_to_waypoint = not specified_a_map
		if specified_a_map then
			open_map_frame_to_map_id = map
		else
			open_map_frame_to_map_id = nil
		end

		if InCombatLockdown() then
			-- addons can't open UI panels like the map during combat
			pinpin_frame.Print("Map will open after combat.")
			do_after_combat_preempt(open_map_frame_do_after_combat_handle)
			open_map_frame_do_after_combat_handle = do_after_combat(OpenWorldMap)
		else
			OpenWorldMap()
		end
	end
end

-- Begin Commands
-- Set a user-specified waypoint, /way [map name|map number] x y [description]
local function way(msg)
	local waypoint = parse_waypoint_command(msg)
	if waypoint then
		set_waypoint(waypoint.uiMapID, waypoint.position, waypoint.desc)
	end
end

-- Waypoint at player position ("way back")
local function wayb()
	local map = C_Map_GetBestMapForUnit(PLAYER)
	local pos = C_Map_GetPlayerMapPosition(map, PLAYER)
	if not pos then
		pinpin_frame.Print("Cannot get player position for this map.")
		return
	end
	set_waypoint(map, pos, "Way Back")
end

-- Clear waypoint
local function wayc()
	if current_waypoint then
		pinpin_frame.Print("Cleared map pin: " .. current_waypoint.string)
		clear_waypoint()
	end
end

-- Generate a link using way syntax or a link to the current waypoint, /wayl [[map name|map number] x y [description]]
local function wayl(msg)
	local waypoint

	if msg ~= "" then
		waypoint = parse_waypoint_command(msg)
		if not waypoint then
			return
		end
		waypoint.string = get_waypoint_string(waypoint)
	else
		waypoint = current_waypoint
		if not waypoint then
			pinpin_frame.Print("There aren't any pins on the map.")
			return
		end
	end

	local map = waypoint.uiMapID
	local map_data = map_id_to_data(map)
	if map_data.requires_pinpin then
		pinpin_frame.Print("Pinning to that map requires PinPin. Are you sure you want to share the pin?")
	end
	local proxy = map_data.proxy
	if proxy then
		local instance, world_pos = C_Map_GetWorldPosFromMapPos(map, waypoint.position)
		local map_pos = select(2, C_Map_GetMapPosFromWorldPos(instance, world_pos, proxy))
		waypoint.uiMapID = proxy
		waypoint.position.x = map_pos.x
		waypoint.position.y = map_pos.y
	end

	local x = math_floor(waypoint.position.x * 10000)
	local y = math_floor(waypoint.position.y * 10000)
	local to_paste = strconcat("|cffffff00|Hworldmap:", waypoint.uiMapID, ":", x, ":", y, "|h[", MAP_PIN_HYPERLINK, "]|h|r") -- server rejects links with text other than "Map Pin" (MAP_PIN_HYPERLINK)
	to_paste = string_join(" ", waypoint.string, to_paste)
	local desc = waypoint.desc
	if desc then
		to_paste = string_join(" ", to_paste, desc)
	end
	if current_waypoint.requires_pinpin then
		to_paste = to_paste .. " (requires PinPin)"
	end
	paste_in_chat(to_paste)
	PlaySound(SOUNDKIT.UI_MAP_WAYPOINT_CHAT_SHARE, nil, SOUNDKIT_ALLOW_DUPLICATES)
end

-- generate a copy-able /run command for people without the addon
local function wayr(msg)
	local waypoint

	if msg ~= "" then
		waypoint = parse_waypoint_command(msg)
		if not waypoint then
			return
		end
		waypoint.string = get_waypoint_string(waypoint)
	else
		waypoint = current_waypoint
		if not waypoint then
			pinpin_frame.Print("There aren't any pins on the map.")
			return
		end
	end

	local map = waypoint.uiMapID
	local map_data = map_id_to_data(map)
	if map_data.requires_pinpin then
		pinpin_frame.Print("Pinning to that map requires PinPin. It can't be shared via a /run command.")
		return
	end
	local proxy = map_data.proxy
	if proxy then
		local instance, world_pos = C_Map_GetWorldPosFromMapPos(map, waypoint.position)
		local map_pos = select(2, C_Map_GetMapPosFromWorldPos(instance, world_pos, proxy))
		waypoint.uiMapID = proxy
		waypoint.position.x = map_pos.x
		waypoint.position.y = map_pos.y
	end

	paste_in_chat(strconcat(" /run C_Map.SetUserWaypoint({uiMapID=", waypoint.uiMapID, ",position={x=", string_format("%.4f", waypoint.position.x), ",y=", string_format("%.4f", waypoint.position.y), "}})"))
end

-- Link a waypoint pointing to the target and some target info in chat
local function wayt()
	local TARGET = "target"
	local map = C_Map_GetBestMapForUnit(PLAYER)

	if not UnitExists(TARGET) then
		pinpin_frame.Print("You have no target.")
		return
	end

	-- get target health percentage
	local target_name = UnitName(TARGET)
	local target_health_proportion = UnitHealth(TARGET) / UnitHealthMax(TARGET)
	local target_health
	if target_health_proportion == 0 then
		target_health = 0
	else
		-- Default to one decimal place, but if health < .1%, then show as many decimals as necessary so we never show 0% when things aren't dead yet
		local multiplier = 100
		repeat
			multiplier = multiplier * 10
			target_health = math_floor(target_health_proportion * multiplier) / (multiplier / 100)
		until target_health > 0
	end

	-- If it's a rare with a map marker visible, we can get its actual position
	local target_guid = UnitGUID(TARGET)
	local vignette_guids = C_VignetteInfo.GetVignettes()
	local target_position
	for _, vignette_guid in ipairs(vignette_guids) do
		if C_VignetteInfo.GetVignetteInfo(vignette_guid).objectGUID == target_guid then
			target_position = C_VignetteInfo.GetVignettePosition(vignette_guid, map)
			break
		end
	end
	local x, y
	if target_position then
		x, y = target_position:GetXY()
	else
		-- Just use the player's position
		local player_pos = C_Map_GetPlayerMapPosition(map, PLAYER)
		if not player_pos then
			pinpin_frame.Print("Can't generate pin for this target (usually because you are in an instance).")
			paste_in_chat(strconcat(target_name, " (", target_health, "%)"))
			return
		end
		x, y = player_pos:GetXY()
	end

	local map_data = map_id_to_data(map)
	if map_data.requires_pinpin then
		pinpin_frame.Print("Pinning to that map requires PinPin. Are you sure you want to share the pin?")
	end
	local proxy = map_data.proxy
	if proxy then
		local instance, world_pos = C_Map_GetWorldPosFromMapPos(map, CreateVector2D(x, y))
		local map_pos = select(2, C_Map_GetMapPosFromWorldPos(instance, world_pos, proxy))
		map = proxy
		x = map_pos.x
		y = map_pos.y
	end

	x = math_floor(x * 10000)
	y = math_floor(y * 10000)

	paste_in_chat(strconcat("|cffffff00|Hworldmap:", map, ":", x, ":", y, "|h[|A:Waypoint-MapPin-ChatIcon:13:13:0:0|a Map Pin Location]|h|r ", target_name, " (", target_health, "%)"))
	PlaySound(SOUNDKIT.UI_MAP_WAYPOINT_CHAT_SHARE, nil, SOUNDKIT_ALLOW_DUPLICATES)
end

-- Paste a waypoint link to the player's position into chat
local function wayme()
	local map = C_Map_GetBestMapForUnit(PLAYER)
	local pos = C_Map_GetPlayerMapPosition(map, PLAYER)
	if not pos then
		pinpin_frame.Print("Player can't be located on this map (usually because you are in an instance).")
		return
	end

	local map_data = map_id_to_data(map)
	if map_data.requires_pinpin then
		pinpin_frame.Print("Pinning to that map requires PinPin. Are you sure you want to share the pin?")
	end
	local proxy = map_data.proxy
	if proxy then
		local instance, world_pos = C_Map_GetWorldPosFromMapPos(map, pos)
		local map_pos = select(2, C_Map_GetMapPosFromWorldPos(instance, world_pos, proxy))
		map = proxy
		pos = map_pos
	end

	local x, y = pos.x, pos.y
	x = math_floor(x * 10000)
	y = math_floor(y * 10000)
	local player_name = UnitName(PLAYER)
	paste_in_chat(strconcat("|cffffff00|Hworldmap:", map, ":", x, ":", y, "|h[", MAP_PIN_HYPERLINK, "]|h|r ", player_name))
	PlaySound(SOUNDKIT.UI_MAP_WAYPOINT_CHAT_SHARE, nil, SOUNDKIT_ALLOW_DUPLICATES)
end

-- Waypoint supertrack toggle
local function ways()
	if not current_waypoint then
		pinpin_frame.Print("There aren't any pins on the map.")
		return
	end

	local supertracking = not C_SuperTrack.IsSuperTrackingUserWaypoint()
	C_SuperTrack_SetSuperTrackedUserWaypoint(supertracking)
	if is_pin_visible_on_open_map() then
		PlaySound(supertracking and SOUNDKIT.UI_MAP_WAYPOINT_SUPER_TRACK_ON or SOUNDKIT.UI_MAP_WAYPOINT_SUPER_TRACK_OFF, nil, SOUNDKIT_ALLOW_DUPLICATES)
	end
end

-- Open options/help
local function wayo()
	InterfaceOptionsFrame_OpenToCategory(pinpin_frame)
end

-- Set a waypoint to the last minimap ping
local wayp, on_minimap_ping
do
	local last_minimap_ping
	local saw_first_ping = false -- different error message if it fails because there hasn't been a ping

	function wayp()
		if last_minimap_ping then
			set_waypoint(last_minimap_ping.uiMapID, last_minimap_ping.position, "Minimap Ping")
		else
			if saw_first_ping then
				pinpin_frame.Print("PinPin couldn't locate the last ping (usually because it was in an instance).")
			else
				pinpin_frame.Print("PinPin hasn't seen any pings yet.")
			end
		end
	end

	-- Event handler for MINIMAP_PING
	function on_minimap_ping(_, minimap_x, minimap_y)
		saw_first_ping = true
		local map = C_Map_GetBestMapForUnit(PLAYER)
		local player_position = C_Map_GetPlayerMapPosition(map, PLAYER)

		if not player_position then
			last_minimap_ping = nil
			return
		end

		local player_x, player_y = player_position:GetXY()
		if C_CVar.GetCVar("rotateMinimap") == "1" then
			minimap_x, minimap_y = unrotate_minimap_coords(minimap_x, minimap_y)
		end

		local map_width, map_height = C_Map.GetMapWorldSize(map)
		local minimap_radius = C_Minimap.GetViewRadius()
		local map_x = player_x + minimap_x * minimap_radius / map_width
		local map_y = player_y - minimap_y * minimap_radius / map_height
		last_minimap_ping = UiMapPoint.CreateFromCoordinates(map, map_x, map_y)
	end
end

local function super_tracking_changed() -- Not being used?
	if not C_SuperTrack.IsSuperTrackingAnything() and current_waypoint and saved_variables.semi_automatic_supertrack_pins then
		C_SuperTrack_SetSuperTrackedUserWaypoint(true)
	end
end

local function on_player_logout()
	if saved_variables.save_logout_waypoint and current_waypoint then
		saved_variables_per_character.logout_waypoint = current_waypoint
	end

	saved_variables_per_character.history = waypoint_history_save()

	PinPinSavedVariables = saved_variables
	PinPinSavedVariablesPerCharacter = saved_variables_per_character
end

-- !!! make the names of the commands in the reference highlighted and clickable - will paste_in_chat the command for them

-- !!! let's add this to the top with some red text and a button to enable In Game Navigation if it's not on when the options panel gets refreshed
if C_CVar.GetCVar("showInGameNavigation") == "0" then
	pinpin_frame.Print("In Game Navigation is disabled!\nMost of PinPin's functionality depends on In Game Navigation.\nSee: Game Menu->Interface->Display")
end

local function check_button_sound(check_button)
	if check_button:GetChecked() then
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
	else
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
	end
end

local function create_check_button(text, tooltip, parent)
	local check_button = CreateFrame("CheckButton", nil, parent)
	check_button:SetSize(26, 26)
	check_button:SetHitRectInsets(0, -100, 0, 0)
	check_button:SetNormalTexture("Interface/Buttons/UI-CheckBox-Up")
	check_button:SetPushedTexture("Interface/Buttons/UI-CheckBox-Down")
	check_button:SetHighlightTexture("Interface/Buttons/UI-CheckBox-Highlight", "ADD")
	check_button:SetCheckedTexture("Interface/Buttons/UI-CheckBox-Check")
	check_button:SetDisabledCheckedTexture("Interface/Buttons/UI-CheckBox-Check-Disabled")
	check_button:SetScript("OnClick", check_button_sound)

	local font_string = check_button:CreateFontString(nil, "ARTWORK", "GameFontHighlightLeft")
	font_string:SetPoint("LEFT", check_button, "RIGHT", 2, 1)
	font_string:SetText(text)
	check_button.label = font_string

	return check_button
end

local function build_options_menu()
	-- Title
	local title = pinpin_frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetJustifyH("LEFT")
	title:SetJustifyV("TOP")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("PinPin")

	-- Description
	local sub_text = pinpin_frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	sub_text:SetNonSpaceWrap(true)
	sub_text:SetMaxLines(3)
	sub_text:SetJustifyH("LEFT")
	sub_text:SetJustifyV("TOP")
	sub_text:SetSize(0, 32)
	sub_text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	sub_text:SetPoint("RIGHT", -32, 0)
	sub_text:SetText("Customize Map Pin behavior and commands.")

	-- Settings
	-- Track New Pins if Not Tracking Anything
	local semi_automatic_supertrack = create_check_button("Track New Pins If Not Tracking Anything", "Switch supertracking to newly placed pins if not tracking anything else.", pinpin_frame)
	semi_automatic_supertrack:SetPoint("TOPLEFT", sub_text, "BOTTOMLEFT", -2, -8) -- !!! 260 x divider
	semi_automatic_supertrack:SetChecked(saved_variables.semi_automatic_supertrack_pins) -- !!! this should be in refresh

	-- Command Prefix
	local prefix = CreateFrame("EditBox", nil, pinpin_frame, "InputBoxTemplate") -- !!! tooltip should show in red that they'll need to reload UI
	prefix:SetAutoFocus(false)
	prefix:SetSize(146, 32)
	prefix:SetPoint("TOPLEFT", semi_automatic_supertrack, "TOPRIGHT", 265, -16)

	local temp_prefix -- !!! clear this on refresh !!! save this as a key on the editbox itself instead
	prefix:HookScript("OnEditFocusLost", function (edit_box)
		temp_prefix = edit_box:GetText()
	end)

	prefix:SetScript("OnShow", function()
		prefix:SetText(temp_prefix or saved_variables.prefix)
	end)

	-- Prefix can't have spaces
	prefix:SetScript("OnSpacePressed", function (edit_box)
		local cursor = edit_box:GetCursorPosition()
		local text = edit_box:GetText()
		edit_box:SetText(string_sub(text, 1, cursor - 1) .. string_sub(text, cursor + 1))
		edit_box:SetCursorPosition(cursor - 1)
	end)

	local prefix_label = prefix:CreateFontString(nil, "BACKGROUND", "GameFontNormal")
	prefix_label:SetText("Command Prefix")
	prefix_label:SetPoint("BOTTOMLEFT", prefix, "TOPLEFT", 0, 3)

	-- Confirm and reload buttons (have to reload for prefix to take effect)
	local prefix_okay = CreateFrame("Button", nil, pinpin_frame, "UIPanelButtonNoTooltipTemplate")
	local prefix_reload = CreateFrame("Button", nil, pinpin_frame, "UIPanelButtonNoTooltipTemplate")
	prefix_okay:SetSize(80, 22)
	prefix_okay:SetText("Okay")
	prefix_okay:SetScript("OnClick", function ()
		PlaySound(SOUNDKIT.GS_TITLE_OPTION_OK)
		local text = prefix:GetText()
		if text ~= "" and text ~= saved_variables.prefix then
			saved_variables.prefix = text
			-- !!! probably play a UI error message telling them they need to reload
			prefix_reload:Show() -- !!! Need to show this after Default too, if the prefix wasn't default (should probably also show a UI error message)
		end
	end)
	prefix_okay:SetPoint("LEFT", prefix, "RIGHT")
	prefix_reload:SetSize(80, 22)
	prefix_reload:SetText("Reload")
	prefix_reload:SetScript("OnClick", function ()
		C_UI.Reload()
	end)
	prefix_reload:SetPoint("LEFT", prefix_okay, "RIGHT")
	prefix_reload:Hide() -- !!! hide this again on refresh when we clear temp_prefix

	-- Always Track New Pins
	local automatic_supertrack = create_check_button("Always Track New Pins", "Automatically switch supertracking to newly placed pins.", pinpin_frame)
	automatic_supertrack:SetPoint("TOPLEFT", semi_automatic_supertrack, "BOTTOMLEFT", 16, -8)
	automatic_supertrack:SetChecked(saved_variables.automatic_supertrack_pins) -- !!! this should be in refresh
	if not saved_variables.semi_automatic_supertrack_pins then -- !!! this should be in refresh
		automatic_supertrack:Disable()
		automatic_supertrack.label:SetTextColor(GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b)
		-- !!! remove tooltip
	end

	-- Unlimited Pin Distance
	local unlimited_pin_distance = create_check_button("Unlimited Pin Distance", "Always show on-screen UI regardless of distance to pin.", pinpin_frame)
	unlimited_pin_distance:SetPoint("TOPLEFT", automatic_supertrack, "BOTTOMLEFT", -16, -8)
	-- !!! -8, -8 for first
end

local function on_addon_loaded()
	-- Default options
	local default_saved_variables = {
		prefix = "way",
		unlimited_pin_distance = true,
		min_pin_distance = 10,
		max_pin_distance = 1000, -- !!! should be greyed out if unlimited pin distance is on
		semi_automatic_supertrack_pins = true, -- !!! this should be greyed out if automatic is on
		automatic_supertrack_pins = true,
		save_logout_waypoint = true,
		automatic_clear = false,
		clear_distance = 10, -- !!! grey out if automatic clear is off
		better_tooltips = true,
	}

	-- Load config
	do
		if PinPinSavedVariables then
			for name, default in pairs(default_saved_variables) do
				local saved = PinPinSavedVariables[name]
				if saved == nil then
					-- Adds the default value for a new option when user updates
					saved_variables[name] = default
				else
					saved_variables[name] = saved
				end
			end
		else
			for name, default in pairs(default_saved_variables) do
				saved_variables[name] = default
			end
		end
	end
	saved_variables_per_character = PinPinSavedVariablesPerCharacter or {}

	-- Build the Interface options panel
	build_options_menu()

	-- Set up slash commands
	do
		local slash_commands = {
			{"", way, {""}},
			{"B", wayb, {"b", "back"}},
			{"M", waym, {"m", "map"}},
			{"C", wayc, {"c", "clear"}},
			{"P", wayp, {"p", "ping"}},
			{"R", wayr, {"r", "run"}},
			{"S", ways, {"s", "super", "supertrack"}},
			{"T", wayt, {"t", "tar", "target"}},
			{"ME", wayme, {"me"}},
			{"L", wayl, {"l", "link"}},
			{"O", wayo, {"o", "option", "options", "h", "help", "pinpin"}}
		}

		local slash_prefix = "/" .. saved_variables.prefix
		for _, slash_command in ipairs(slash_commands) do
			for j, command in ipairs(slash_command[3]) do
				_G[strconcat("SLASH_PINPIN_WAY", slash_command[1], j)] = slash_prefix .. command
			end
			SlashCmdList["PINPIN_WAY" .. slash_command[1]] = slash_command[2]
		end
	end

	-- Set up event handlers
	do
		pinpin_frame:UnregisterEvent("ADDON_LOADED")
		local event_handlers = {
			PLAYER_LOGOUT = on_player_logout,
			MINIMAP_PING = on_minimap_ping,
			SUPER_TRACKING_CHANGED = on_super_tracking_changed,
			PLAYER_REGEN_ENABLED = on_player_regen_enabled
		}

		for event in pairs(event_handlers) do
			pinpin_frame:RegisterEvent(event)
		end

		pinpin_frame:SetScript("OnEvent", function(self, event, ...)
			event_handlers[event](...)
		end)
	end

	-- Restore logout waypoint
	if saved_variables.save_logout_waypoint then
		local logout_waypoint = saved_variables_per_character.logout_waypoint
		if logout_waypoint then
			set_waypoint(logout_waypoint.uiMapID, logout_waypoint.position, logout_waypoint.desc)
		end
	end
	saved_variables_per_character.logout_waypoint = nil

	-- Restore waypoint history (must be after restore logout waypoint to avoid a duplicate history entry)
	waypoint_history_restore(saved_variables.history)
	saved_variables.history = nil

	-- Create an options panel
	-- !!! add ui
	-- !!! put a command reference here too
	InterfaceOptions_AddCategory(pinpin_frame)
	InterfaceAddOnsList_Update() -- fix Blizzard UI bug (otherwise OpenToCategory doesn't work on first run)

	function pinpin_frame:okay()
		pinpin_frame.Print("Okay!")
	end

	function pinpin_frame:cancel()
		pinpin_frame.Print("Cancel :(")
	end

	function pinpin_frame:default()
		pinpin_frame.Print("Default!")
	end

	function pinpin_frame:refresh()
		pinpin_frame.Print("Refreshing!")
	end
end

pinpin_frame:RegisterEvent("ADDON_LOADED")
pinpin_frame:SetScript("OnEvent", function(self, event, addon)
	if event == "ADDON_LOADED" and addon == "PinPin" then
		on_addon_loaded()
	end
end)