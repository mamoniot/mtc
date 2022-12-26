local flib_migration = require("__flib__.migration")


local migrations_table = {
	["1.0.6"] = function()
		---@type MapData
		local map_data = global
		for k, v in pairs(map_data.available_trains) do
			for id, _ in pairs(v) do
				local train = map_data.trains[id]
				train.is_available = true
			end
		end
		for k, v in pairs(map_data.trains) do
			v.depot = nil
			if not v.is_available then
				v.depot_id = nil
			end
		end
	end,
	["1.0.7"] = function()
		---@type MapData
		local map_data = global
		map_data.available_trains = {}
		for id, v in pairs(map_data.trains) do
			v.parked_at_depot_id = v.depot_id
			v.depot_id = nil
			v.se_is_being_teleported = not v.entity and true or nil
			--NOTE: we are guessing here because this information was never saved
			v.se_depot_surface_i = v.entity.front_stock.surface.index
			v.is_available = nil
			if v.parked_at_depot_id and v.network_name then
				local network = map_data.available_trains[v.network_name--[[@as string]]]
				if not network then
					network = {}
					map_data.available_trains[v.network_name--[[@as string]]] = network
				end
				network[id] = true
				v.is_available = true
			end
		end
	end,
	["1.0.8"] = function()
		---@type MapData
		local map_data = global
		for id, station in pairs(map_data.stations) do
			local params = get_comb_params(station.entity_comb1)
			if params.operation == MODE_PRIMARY_IO_FAILED_REQUEST then
				station.display_state = 1
			elseif params.operation == MODE_PRIMARY_IO_ACTIVE then
				station.display_state = 2
			else
				station.display_state = 0
			end
			station.display_failed_request = nil
			station.update_display = nil
		end
	end,
	["1.1.0"] = function()
		---@type MapData
		local map_data = global
		map_data.refuelers = {}
		map_data.to_refuelers = {}
		for id, station in pairs(map_data.stations) do
			station.p_count_or_r_threshold_per_item = nil
		end

		local OLD_STATUS_R_TO_D = 5
		local NEW_STATUS_TO_D = 5
		local NEW_STATUS_TO_D_BYPASS = 6
		for id, train in pairs(map_data.trains) do
			if train.status == OLD_STATUS_R_TO_D then
				train.manifest = nil
				train.p_station_id = nil
				train.r_station_id = nil
				if train.is_available then
					train.status = NEW_STATUS_TO_D_BYPASS
				else
					train.status = NEW_STATUS_TO_D
				end
			end
		end
	end,
	["1.1.2"] = function()
		---@type MapData
		local map_data = global
		map_data.refuelers = map_data.refuelers or {}
		map_data.to_refuelers = map_data.to_refuelers or {}
	end,
	["1.1.3"] = function()
		---@type MapData
		local map_data = global
		for k, v in pairs(map_data.refuelers) do
			if not v.entity_comb.valid or not v.entity_stop.valid then
				map_data.refuelers[k] = nil
			end
		end
	end,
	["1.2.0"] = function()
		---@type MapData
		local map_data = global

		map_data.each_refuelers = {}
		map_data.se_tele_old_id = nil

		for k, comb in pairs(map_data.to_comb) do
			local control = get_comb_control(comb)
			local params = control.parameters
			local bits = params.second_constant or 0
			local allows_all_trains = bits%2
			local is_pr_state = math.floor(bits/2)%3

			local new_bits = bit32.bor(is_pr_state, allows_all_trains*4)
			params.second_constant = new_bits

			control.parameters = params
		end
		for id, station in pairs(map_data.stations) do
			station.display_state = (station.display_state >= 2 and 1 or 0) + (station.display_state%2)*2

			set_station_from_comb_state(station)
			update_stop_if_auto(map_data, station, true)
		end

		map_data.layout_train_count = {}
		for id, train in pairs(map_data.trains) do
			map_data.layout_train_count[train.layout_id] = (map_data.layout_train_count[train.layout_id] or 0) + 1
		end
		for layout_id, _ in pairs(map_data.layouts) do
			if not map_data.layout_train_count[layout_id] then
				map_data.layouts[layout_id] = nil
				for id, station in pairs(map_data.stations) do
					station.accepted_layouts[layout_id] = nil
				end
			end
		end
	end,
	["1.2.2"] = function()
		---@type MapData
		local map_data = global


	end
}
--STATUS_R_TO_D = 5

---@param data ConfigurationChangedData
function on_config_changed(data)
	global.tick_state = STATE_INIT
	global.tick_data = {}
	flib_migration.on_config_changed(data, migrations_table)

	IS_SE_PRESENT = remote.interfaces["space-exploration"] ~= nil
	if IS_SE_PRESENT and not global.se_tele_old_id then
		global.se_tele_old_id = {}
	end
end
