--By Mami
local flib_event = require("__flib__.event")

---@param map_data MapData
---@param train Train
local function on_failed_delivery(map_data, train)
	--NOTE: must change train status to STATUS_D or remove it from tracked trains after this call
	local is_p_delivery_made = train.status ~= STATUS_D_TO_P and train.status ~= STATUS_P
	if not is_p_delivery_made then
		local station = map_data.stations[train.p_station_id]
		remove_manifest(map_data, station, train.manifest, 1)
		if train.status == STATUS_P then
			set_combinator_output(map_data, station.entity_comb1, nil)
			unset_wagon_combs(map_data, station)
		end
	end
	local is_r_delivery_made = train.status == STATUS_R_TO_D
	if not is_r_delivery_made then
		local station = map_data.stations[train.r_station_id]
		remove_manifest(map_data, station, train.manifest, -1)
		if train.status == STATUS_R then
			set_combinator_output(map_data, station.entity_comb1, nil)
			unset_wagon_combs(map_data, station)
		end
	end
	train.r_station_id = 0
	train.p_station_id = 0
	train.manifest = nil
end


---@param map_data MapData
---@param depot Depot
---@param train_id uint
local function add_available_train(map_data, depot, train_id)
	if depot.network_name then
		local network = map_data.trains_available[depot.network_name]
		if not network then
			network = {}
			map_data.trains_available[depot.network_name] = network
		end
		network[train_id] = depot.entity_stop.unit_number
	end
	depot.available_train = train_id
	local train = map_data.trains[train_id]
	train.depot_name = depot.entity_stop.backer_name
	train.depot = depot
end
---@param map_data MapData
---@param depot Depot
function remove_available_train(map_data, depot)
	if depot.available_train then
		if depot.network_name then
			local network = map_data.trains_available[depot.network_name]
			if network then
				network[depot.available_train] = nil
				if next(network) == nil then
					map_data.trains_available[depot.network_name] = nil
				end
			end
		end
		local train = map_data.trains[depot.available_train]
		train.depot = nil
		depot.available_train = nil
	end
end


---@param map_data MapData
---@param stop LuaEntity
---@param comb LuaEntity
local function on_depot_built(map_data, stop, comb, control)
	local depot = {
		entity_stop = stop,
		entity_comb = comb,
		network_name = control.first_signal and control.first_signal.name or nil,
		priority = 0,
		network_flag = 0,
	}
	map_data.depots[stop.unit_number] = depot
end

local function on_depot_broken(map_data, depot)
	--remove train
	if depot.available_train then
		--NOTE: we could remove the schedule from this train
		--local train = map_data.trains[depot.available_train]
		map_data.trains[depot.available_train] = nil
		remove_available_train(map_data, depot)
	end
	map_data.depots[depot.entity_stop.unit_number] = nil
end

---@param map_data MapData
---@param stop LuaEntity
---@param comb1 LuaEntity
---@param comb2 LuaEntity
---@param control ArithmeticCombinatorParameters
local function on_station_built(map_data, stop, comb1, comb2, control)
	local station = {
		entity_stop = stop,
		entity_comb1 = comb1,
		entity_comb2 = comb2,
		wagon_combs = nil,
		deliveries_total = 0,
		last_delivery_tick = 0,
		priority = 0,
		r_threshold = 0,
		p_threshold = 0,
		locked_slots = 0,
		network_name = control.first_signal and control.first_signal.name or nil,
		network_flag = 0,
		deliveries = {},
		is_all = control.second_constant == 1,
		accepted_layouts = {},
		layout_pattern = nil,
	}
	map_data.stations[stop.unit_number] = station

	update_station_if_auto(map_data, station, nil)
end
---@param map_data MapData
---@param station_id uint
---@param station Station
local function on_station_broken(map_data, station_id, station)
	if station.deliveries_total > 0 then
		--search for trains coming to the destroyed station
		for train_id, train in pairs(map_data.trains) do
			local is_r = train.r_station_id == station_id
			local is_p = train.p_station_id == station_id
			if is_p or is_r then
				local is_p_delivery_made = train.status ~= STATUS_D_TO_P and train.status ~= STATUS_P
				local is_r_delivery_made = train.status == STATUS_R_TO_D
				if (is_r and not is_r_delivery_made) or (is_p and not is_p_delivery_made) then
					--train is attempting delivery to a stop that was destroyed, stop it
					on_failed_delivery(map_data, train)
					train.entity.schedule = nil
					remove_train(map_data, train, train_id)
					send_lost_train_alert(train.entity)
				end
			end
		end
	end
	map_data.stations[station_id] = nil
end

---@param map_data MapData
---@param stop LuaEntity
---@param comb_operation string
---@param comb_forbidden LuaEntity?
local function search_for_station_combinator(map_data, stop, comb_operation, comb_forbidden)
	local pos_x = stop.position.x
	local pos_y = stop.position.y
	local search_area = {
		{pos_x - 2, pos_y - 2},
		{pos_x + 2, pos_y + 2}
	}
	local entities = stop.surface.find_entities(search_area)
	for _, entity in pairs(entities) do
		if
		entity.valid and entity.name == COMBINATOR_NAME and
		entity ~= comb_forbidden and map_data.to_stop[entity.unit_number] == stop
		then
			local control = entity.get_or_create_control_behavior().parameters--[[@as ArithmeticCombinatorParameters]]
			if control.operation == comb_operation then
				return entity
			end
		end
	end
end

---@param map_data MapData
---@param comb LuaEntity
local function on_combinator_built(map_data, comb)
	local pos_x = comb.position.x
	local pos_y = comb.position.y

	local search_area
	if comb.direction == defines.direction.north or comb.direction == defines.direction.south then
		search_area = {
			{pos_x - 1.5, pos_y - 2},
			{pos_x + 1.5, pos_y + 2}
		}
	else
		search_area = {
			{pos_x - 2, pos_y - 1.5},
			{pos_x + 2, pos_y + 1.5}
		}
	end
	local stop = nil
	local rail = nil
	local entities = comb.surface.find_entities(search_area)
	for _, cur_entity in pairs(entities) do
		if cur_entity.valid then
			if cur_entity.name == "train-stop" then
				--NOTE: if there are multiple stops we take the later one
				stop = cur_entity
			elseif cur_entity.name == "straight-rail" then
				rail = cur_entity
			end
		end
	end

	local out = comb.surface.create_entity({
		name = COMBINATOR_OUT_NAME,
		position = comb.position,
		force = comb.force
	})
	assert(out, "cybersyn: could not spawn combinator controller")
	comb.connect_neighbour({
		target_entity = out,
		source_circuit_id = defines.circuit_connector_id.combinator_output,
		wire = defines.wire_type.green,
	})
	comb.connect_neighbour({
		target_entity = out,
		source_circuit_id = defines.circuit_connector_id.combinator_output,
		wire = defines.wire_type.red,
	})

	map_data.to_comb[comb.unit_number] = comb
	map_data.to_output[comb.unit_number] = out
	map_data.to_stop[comb.unit_number] = stop

	local a = comb.get_or_create_control_behavior()--[[@as LuaArithmeticCombinatorControlBehavior]]
	local control = a.parameters
	if control.operation == OPERATION_DEFAULT then
		control.operation = OPERATION_PRIMARY_IO
		control.first_signal = NETWORK_SIGNAL_DEFAULT
		a.parameters = control
	end
	if control.operation == OPERATION_WAGON_MANIFEST then
		if rail then
			force_update_station_from_rail(map_data, rail, nil)
		end
	elseif control.operation == OPERATION_DEPOT then
		if stop then
			local station = map_data.stations[stop.unit_number]
			---@type Depot
			local depot = map_data.depots[stop.unit_number]
			if depot or station then
				--NOTE: repeated combinators are ignored
			else
				on_depot_built(map_data, stop, comb, control)
			end
		end
	elseif control.operation == OPERATION_SECONDARY_IO then
		if stop then
			local station = map_data.stations[stop.unit_number]
			if station and not station.entity_comb2 then
				station.entity_comb2 = comb
			end
		end
	elseif stop then
		control.operation = OPERATION_PRIMARY_IO
		local station = map_data.stations[stop.unit_number]
		local depot = map_data.depots[stop.unit_number]
		if station then
			--NOTE: repeated combinators are ignored
		else
			if depot then
				--NOTE: this will disrupt deliveries in progress that where dispatched from this station in a minor way
				map_data.depots[stop.unit_number] = nil
			end
			--no station or depot
			--add station

			local comb2 = search_for_station_combinator(map_data, stop, OPERATION_SECONDARY_IO, comb)

			on_station_built(map_data, stop, comb, comb2, control)
		end
	end
end
---@param map_data MapData
---@param comb LuaEntity
---@param network_name string?
function on_combinator_network_updated(map_data, comb, network_name)
	local stop = map_data.to_stop[comb.unit_number]

	if stop and stop.valid then
		local station = map_data.stations[stop.unit_number]
		if station then
			if station.entity_comb1 == comb then
				station.network_name = network_name
			end
		else
			local depot = map_data.depots[stop.unit_number]
			if depot.entity_comb == comb then
				if depot.available_train then
					---@type uint
					local train_id = depot.available_train
					remove_available_train(map_data, depot)
					depot.network_name = network_name
					add_available_train(map_data, depot, train_id)
				else
					depot.network_name = network_name
				end
			end
		end
	end
end
---@param map_data MapData
---@param comb LuaEntity
local function on_combinator_broken(map_data, comb)
	--NOTE: we do not check for wagon manifest combinators and update their stations, it is assumed they will be lazy deleted later
	local out = map_data.to_output[comb.unit_number]
	local stop = map_data.to_stop[comb.unit_number]

	if stop and stop.valid then
		local station = map_data.stations[stop.unit_number]
		if station then
			if station.entity_comb1 == comb then
				local comb1 = search_for_station_combinator(map_data, stop, OPERATION_PRIMARY_IO, comb)
				if comb1 then
					station.entity_comb1 = comb1
					local control = comb1.get_or_create_control_behavior().parameters--[[@as ArithmeticCombinatorParameters]]
					station.network_name = control.first_signal and control.first_signal.name
				else
					on_station_broken(map_data, stop.unit_number, station)
					local depot_comb = search_for_station_combinator(map_data, stop, OPERATION_DEPOT, comb)
					if depot_comb then
						local control = depot_comb.get_or_create_control_behavior().parameters--[[@as ArithmeticCombinatorParameters]]
						on_depot_built(map_data, stop, depot_comb, control.first_signal)
					end
				end
			elseif station.entity_comb2 == comb then
				station.entity_comb2 = search_for_station_combinator(map_data, stop, OPERATION_SECONDARY_IO, comb)
			end
		else
			local depot = map_data.depots[stop.unit_number]
			if depot and depot.entity_comb == comb then
				--NOTE: this will disrupt deliveries in progress that where dispatched from this station in a minor way
				local depot_comb = search_for_station_combinator(map_data, stop, OPERATION_DEPOT, comb)
				if depot_comb then
					local control = depot_comb.get_or_create_control_behavior().parameters--[[@as ArithmeticCombinatorParameters]]
					depot.entity_comb = depot_comb
					depot.network_name = control.first_signal and control.first_signal.name
				else
					on_depot_broken(map_data, depot)
				end
			end
		end
	end

	if out and out.valid then
		out.destroy()
	end
	map_data.to_comb[comb.unit_number] = nil
	map_data.to_output[comb.unit_number] = nil
	map_data.to_stop[comb.unit_number] = nil
end
---@param map_data MapData
---@param comb LuaEntity
function on_combinator_updated(map_data, comb)
	--NOTE: this is the lazy way to implement updates and puts strong restrictions on data validity on on_combinator_broken
	on_combinator_broken(map_data, comb)
	on_combinator_built(map_data, comb)
end

---@param map_data MapData
---@param stop LuaEntity
local function on_stop_built(map_data, stop)
	local pos_x = stop.position.x
	local pos_y = stop.position.y

	local search_area = {
		{pos_x - 2, pos_y - 2},
		{pos_x + 2, pos_y + 2}
	}
	local comb2 = nil
	local comb1 = nil
	local depot_comb = nil
	local entities = stop.surface.find_entities(search_area)
	for _, entity in pairs(entities) do
		if entity.valid and entity.name == COMBINATOR_NAME and map_data.to_stop[entity.unit_number] == nil then
			map_data.to_stop[entity.unit_number] = stop
			local control = entity.get_or_create_control_behavior().parameters--[[@as ArithmeticCombinatorParameters]]
			if control.operation == OPERATION_PRIMARY_IO then
				comb1 = entity
			elseif control.operation == OPERATION_SECONDARY_IO then
				comb2 = entity
			elseif control.operation == OPERATION_DEPOT then
				depot_comb = entity
			end
		end
	end
	if comb1 then
		on_station_built(map_data, stop, comb1, comb2, comb1.get_or_create_control_behavior().parameters--[[@as ArithmeticCombinatorParameters]])
	elseif depot_comb then
		on_depot_built(map_data, stop, depot_comb, depot_comb.get_or_create_control_behavior().parameters--[[@as ArithmeticCombinatorParameters]])
	end
end
---@param map_data MapData
---@param stop LuaEntity
local function on_stop_broken(map_data, stop)
	local pos_x = stop.position.x
	local pos_y = stop.position.y

	local search_area = {
		{pos_x - 2, pos_y - 2},
		{pos_x + 2, pos_y + 2}
	}
	local entities = stop.surface.find_entities(search_area)
	for _, entity in pairs(entities) do
		if entity.valid and map_data.to_stop[entity.unit_number] == stop then
			map_data.to_stop[entity.unit_number] = nil
		end
	end

	local station = map_data.stations[stop.unit_number]
	if station then
		on_station_broken(map_data, stop.unit_number, station)
	else
		local depot = map_data.depots[stop.unit_number]
		if depot then
			on_depot_broken(map_data, depot)
		end
	end
end
---@param map_data MapData
---@param stop LuaEntity
local function on_station_rename(map_data, stop)
	--search for trains coming to the renamed station
	local station_id = stop.unit_number
	local station = map_data.stations[station_id]
	if station and station.deliveries_total > 0 then
		for train_id, train in pairs(map_data.trains) do
			local is_p = train.p_station_id == station_id
			local is_r = train.r_station_id == station_id
			if is_p or is_r then
				local is_p_delivery_made = train.status ~= STATUS_D_TO_P and train.status ~= STATUS_P
				local is_r_delivery_made = train.status == STATUS_R_TO_D
				if (is_r and not is_r_delivery_made) or (is_p and not is_p_delivery_made) then
					--train is attempting delivery to a stop that was renamed
					local p_station = map_data.stations[train.p_station_id]
					local r_station = map_data.stations[train.r_station_id]
					local schedule = create_manifest_schedule(train.depot_name, p_station.entity_stop, r_station.entity_stop, train.manifest)
					schedule.current = train.entity.schedule.current
					train.entity.schedule = schedule
				end
			end
		end
	else
		local depot = map_data.depots[station_id]
		if depot and depot.available_train then
			local train = map_data.trains[depot.available_train]
			train.depot_name = stop.backer_name
		end
	end
end


---@param map_data MapData
local function find_and_add_all_stations_from_nothing(map_data)
	for _, surface in pairs(game.surfaces) do
		local entities = surface.find_entities_filtered({name = COMBINATOR_NAME})
		for k, comb in pairs(entities) do
			if comb.valid then
				on_combinator_built(map_data, comb)
			end
		end
	end
end

---@param map_data MapData
---@param depot Depot
---@param train_entity LuaTrain
local function on_train_arrives_depot(map_data, depot, train_entity)
	local contents = train_entity.get_contents()
	local train_id = train_entity.id
	local train = map_data.trains[train_id]
	if train then
		if train.manifest and train.status == STATUS_R_TO_D then
			--succeeded delivery
			train.p_station_id = 0
			train.r_station_id = 0
			train.manifest = nil
			train.status = STATUS_D
			add_available_train(map_data, depot, train_id)
		else
			if train.manifest then
				on_failed_delivery(map_data, train)
				send_lost_train_alert(train.entity)
			end
			train.status = STATUS_D
			add_available_train(map_data, depot, train_id)
		end
		if next(contents) ~= nil then
			--train still has cargo
			train_entity.schedule = nil
			remove_train(map_data, train, train_id)
			send_nonempty_train_in_depot_alert(train_entity)
		else
			train_entity.schedule = create_depot_schedule(train.depot_name)
		end
	elseif next(contents) == nil then
		train = {
			--depot_name = train_entity.station.backer_name,
			--depot = depot,
			status = STATUS_D,
			entity = train_entity,
			layout_id = 0,
			item_slot_capacity = 0,
			fluid_capacity = 0,
			p_station_id = 0,
			r_station_id = 0,
			manifest = nil,
		}
		update_train_layout(map_data, train)
		map_data.trains[train_id] = train
		add_available_train(map_data, depot, train_id)
		local schedule = create_depot_schedule(train.depot_name)
		train_entity.schedule = schedule
	else
		send_nonempty_train_in_depot_alert(train_entity)
	end
end
---@param map_data MapData
---@param stop LuaEntity
---@param train Train
local function on_train_arrives_buffer(map_data, stop, train)
	if train.manifest then
		---@type uint
		local station_id = stop.unit_number
		if train.status == STATUS_D_TO_P then
			if train.p_station_id == station_id then
				train.status = STATUS_P
				--change circuit outputs
				local station = map_data.stations[station_id]
				local signals = {}
				for i, item in ipairs(train.manifest) do
					signals[i] = {index = i, signal = {type = item.type, name = item.name}, count = item.count}
				end
				set_combinator_output(map_data, station.entity_comb1, signals)
				set_p_wagon_combs(map_data, station, train)
			end
		elseif train.status == STATUS_P_TO_R then
			if train.r_station_id == station_id then
				train.status = STATUS_R
				--change circuit outputs
				local station = map_data.stations[station_id]
				local signals = {}
				for i, item in ipairs(train.manifest) do
					signals[i] = {index = i, signal = {type = item.type, name = item.name}, count = -item.count}
				end
				set_combinator_output(map_data, station.entity_comb1, signals)
				set_r_wagon_combs(map_data, station, train)
			end
		else
			on_failed_delivery(map_data, train)
			remove_train(map_data, train, train.entity.id)
			train.entity.schedule = nil
			send_lost_train_alert(train.entity)
		end
	else
		--train is lost somehow, probably from player intervention
		remove_train(map_data, train, train.entity.id)
	end
end
---@param map_data MapData
---@param train Train
local function on_train_leaves_station(map_data, train)
	if train.manifest then
		if train.status == STATUS_P then
			train.status = STATUS_P_TO_R
			local station = map_data.stations[train.p_station_id]
			remove_manifest(map_data, station, train.manifest, 1)
			set_combinator_output(map_data, station.entity_comb1, nil)
			unset_wagon_combs(map_data, station)
		elseif train.status == STATUS_R then
			train.status = STATUS_R_TO_D
			local station = map_data.stations[train.r_station_id]
			remove_manifest(map_data, station, train.manifest, -1)
			set_combinator_output(map_data, station.entity_comb1, nil)
			unset_wagon_combs(map_data, station)
		end
	elseif train.depot then
		remove_available_train(map_data, train.depot)
	end
end


---@param map_data MapData
---@param train Train
local function on_train_broken(map_data, train)
	if train.manifest then
		on_failed_delivery(map_data, train)
		remove_train(map_data, train, train.entity.id)
		if train.entity.valid then
			train.entity.schedule = nil
		end
	end
end
---@param map_data MapData
---@param pre_train_id uint
---@param train_entity LuaEntity
local function on_train_modified(map_data, pre_train_id, train_entity)
	local train = map_data.trains[pre_train_id]
	if train then
		if train.manifest then
			on_failed_delivery(map_data, train)
		end
		remove_train(map_data, train, pre_train_id)
		if train.entity.valid then
			train.entity.schedule = nil
		end
	end
end


local function on_built(event)
	local entity = event.entity or event.created_entity or event.destination
	if not entity or not entity.valid then return end

	if entity.name == "train-stop" then
		on_stop_built(global, entity)
	elseif entity.name == COMBINATOR_NAME then
		on_combinator_built(global, entity)
	elseif entity.type == "inserter" then
		update_station_from_inserter(global, entity)
	elseif entity.type == "pump" then
		update_station_from_pump(global, entity)
	elseif entity.type == "straight-rail" then
		update_station_from_rail(global, entity)
	end
end
local function on_broken(event)
	local entity = event.entity
	if not entity or not entity.valid then return end

	if entity.train then
		local train = global.trains[entity.train.id]
		if train then
			on_train_broken(global, train)
		end
	elseif entity.name == "train-stop" then
		on_stop_broken(global, entity)
	elseif entity.name == COMBINATOR_NAME then
		on_combinator_broken(global, entity)
	elseif entity.type == "inserter" then
		update_station_from_inserter(global, entity, entity)
	elseif entity.type == "pump" then
		update_station_from_pump(global, entity, entity)
	elseif entity.type == "straight-rail" then
		update_station_from_rail(global, entity, nil)
	end
end
local function on_rename(event)
	if event.entity.name == "train-stop" then
		on_station_rename(global, event.entity)
	end
end

local function on_train_built(event)
	local train_e = event.train
	if event.old_train_id_1 then
		on_train_modified(global, event.old_train_id_1, train_e)
	end
	if event.old_train_id_2 then
		on_train_modified(global, event.old_train_id_2, train_e)
	end
end
local function on_train_changed(event)
	local train_e = event.train
	local train = global.trains[train_e.id]
	if train_e.state == defines.train_state.wait_station then
		local stop = train_e.station
		if stop and stop.valid and stop.name == "train-stop" then
			if global.stations[stop.unit_number] then
				on_train_arrives_buffer(global, stop, train)
			else
				local depot = global.depots[stop.unit_number]
				if depot then
					on_train_arrives_depot(global, depot, train_e)
				end
			end
		end
	elseif event.old_state == defines.train_state.wait_station then
		if train then
			on_train_leaves_station(global, train)
		end
	end
end

local function on_surface_removed(event)
	local surface = game.surfaces[event.surface_index]
	if surface then
		local train_stops = surface.find_entities_filtered({type = "train-stop"})
		for _, entity in pairs(train_stops) do
			if entity.name == "train-stop" then
				on_stop_broken(global, entity)
			end
		end
	end
end

local function on_paste(event)
	local entity = event.destination
	if not entity or not entity.valid then return end

	if entity.name == COMBINATOR_NAME then
		on_combinator_updated(global, entity)
	end
end

local function on_settings_changed(event)
	mod_settings.tps = settings.global["cybersyn-ticks-per-second"].value --[[@as int]]
	mod_settings.r_threshold = settings.global["cybersyn-request-threshold"].value--[[@as int]]
	mod_settings.p_threshold = settings.global["cybersyn-provide-threshold"].value--[[@as int]]
	mod_settings.network_flag = settings.global["cybersyn-network-flag"].value--[[@as int]]
	if event.setting == "cybersyn-ticks-per-second" then
		local nth_tick = math.ceil(60/mod_settings.tps);
		flib_event.on_nth_tick(nil)
		flib_event.on_nth_tick(nth_tick, function()
			tick(global, mod_settings)
		end)
	end
end


local filter_built = {
	{filter = "type", type = "train-stop"},
	{filter = "type", type = "arithmetic-combinator"},
	{filter = "type", type = "inserter"},
	{filter = "type", type = "pump"},
	{filter = "type", type = "straight-rail"},
}
local filter_broken = {
	{filter = "type", type = "train-stop"},
	{filter = "type", type = "arithmetic-combinator"},
	{filter = "type", type = "inserter"},
	{filter = "type", type = "pump"},
	{filter = "type", type = "straight-rail"},
	{filter = "rolling-stock"},
}
local filter_comb = {
	{filter = "type", type = "arithmetic-combinator"},
}
local function main()
	mod_settings.tps = settings.global["cybersyn-ticks-per-second"].value --[[@as int]]
	mod_settings.r_threshold = settings.global["cybersyn-request-threshold"].value--[[@as int]]
	mod_settings.p_threshold = settings.global["cybersyn-provide-threshold"].value--[[@as int]]
	mod_settings.network_flag = settings.global["cybersyn-network-flag"].value--[[@as int]]

	--NOTE: I have no idea if this correctly registers all events once in all situations
	flib_event.register(defines.events.on_built_entity, on_built, filter_built)
	flib_event.register(defines.events.on_robot_built_entity, on_built, filter_built)
	flib_event.register({defines.events.script_raised_built, defines.events.script_raised_revive, defines.events.on_entity_cloned}, on_built)

	flib_event.register(defines.events.on_pre_player_mined_item, on_broken, filter_broken)
	flib_event.register(defines.events.on_robot_pre_mined, on_broken, filter_broken)
	flib_event.register(defines.events.on_entity_died, on_broken, filter_broken)
	flib_event.register(defines.events.script_raised_destroy, on_broken)

	flib_event.register({defines.events.on_pre_surface_deleted, defines.events.on_pre_surface_cleared}, on_surface_removed)

	flib_event.register(defines.events.on_entity_settings_pasted, on_paste)

	local nth_tick = math.ceil(60/mod_settings.tps);
	flib_event.on_nth_tick(nth_tick, function(event)
		tick(global, mod_settings)
	end)

	flib_event.register(defines.events.on_train_created, on_train_built)
	flib_event.register(defines.events.on_train_changed_state, on_train_changed)

	flib_event.register(defines.events.on_entity_renamed, on_rename)

	flib_event.register(defines.events.on_runtime_mod_setting_changed, on_settings_changed)

	register_gui_actions()

	flib_event.on_init(init_global)
end


main()