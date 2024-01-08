--[[
	-- Credits

    - Yokai - script base from 12-23-2022
	- Dareks - further edits to make script more realistic and adjustable to every car -- 29-12-2023
	- CheesyManiac - ignition and engine starter script - doesn't really work here, dunno why :<

	-- TODO:
		--	chassis driving modes - press a button - comfort, sport, track, race etc.
		--	gearbox driving modes - use shifter to select !!!/ press a button - reverse, neutral, drive, sport, track, race etc.
		--  shift lock for manual gear change - full lock for older cars should work, just change one value in the code below.
		--	other forgotten stuff :) - yes
	--]]

------------------------------------------------------------------------------------------------------------------

-- General Interpolations
-- (aka range) converts an input between x1 and x2, to an output between y1 and y2
local function interpolate(x1, x2, input, y1, y2)
	input = math.clamp(input, x1, x2)
	return y1 + ((input - x1) / (x2 - x1)) * (y2 - y1)
end

local function interpolate_v2(x1, x2, x3, input, y1, y2, y2)
	input = math.clamp(input, x1, x2, x3)
	return y1 + ((input - x1) / (x3 - x2 - x1)) * (y3 - y2 - y1)
end

local function safe(input) -- help prevent stupid issues when logging
	if type(input) == "table" then
		return "table"
	end
	return input
end
local function log(input)
	if true then
		ac.log("![auto] " .. safe(input))
	end
end
local function bug(name, value)
	if true then
		ac.debug("![auto] " .. name, value)
	end
end

------------------------------------------------------------------------------------------------------------------

-- Locals - Controls

local prefix = "__EXT_CAR_"
local postfixDown = "_DN"
local postfixUp = "_UP"

local driveModeButtonDown = ac.ControlButton(prefix .. "DRIVE_MODE" .. postfixDown)
local driveModeButtonUp = ac.ControlButton(prefix .. "DRIVE_MODE" .. postfixUp)

local driveModeButtonMPS = {}
-- Starting at 2 so that the drivemodes line up with the GearboxDriveModes
for i = 2, 4 do
	driveModeButtonMPS[i] = ac.ControlButton(prefix .. "DRIVE_MODE" .. "_" .. i - 1)
end

local reverseGearButton = ac.ControlButton(prefix .. "REVERSE_GEAR")
local neutralGearButton = ac.ControlButton(prefix .. "NEUTRAL_GEAR")
local manualModeButton = ac.ControlButton(prefix .. "MANUAL_MODE")
local launchControlActiveButton = ac.ControlButton(prefix .. "LAUNCH_CONTROL_ACTIVE")
local launchControlDownButton = ac.ControlButton(prefix .. "LAUNCH_CONTROL_DN")
local launchControlUpButton = ac.ControlButton(prefix .. "LAUNCH_CONTROL_UP")

-- Locals - General
local is_car_script = (ac.accessCarPhysics ~= nil)
ac.log("is_car_script: " .. (is_car_script and "true" or "false"))

local data = is_car_script
local data = ac.accessCarPhysics()
--local data = ac.getJoypadState()
local car = ac.getCar(0)
local phy = ac.getCarPhysics(0)
local gear, speed, rpm, throttle, braking = 0, 0, 0, 0, 0
local auto = {}
local target = 0
local target_max = 0
local ready = false
local shift_lock = 0
local shift_paddle_lock = 0
local kickdown = false
local kickdown_gear = 0
local logic_gear_up = 0
local logic_gear_dn = 0
local paddle_shift_up = ac.isControllerGearUpPressed()
local paddle_shift_dn = ac.isControllerGearDownPressed()
local allow_paddle_shift = false
local shift_lag = 0.25

-- Locals - Launch Control

local lc_counter = 0
local launch_control_ready = 0
local launch_control_on = 0
local launch_control_rpm = 4000
local launch_control_speed = 38
local stock_final_drive = 2.56 -- take the value from "your car / drivetrain.ini / gears / final"

-- Locals - Gearbox Driving Modes

local gearbox_valve_1 = false
local gearbox_valve_2 = false
local gearbox_valve_overdrive = false
local autoShift = ac.autoShift
local throttle_mode_normal = false
local throttle_mode_sport = false
local throttle_mode_race = false

---@alias GearboxDriveModes
---| `GearboxDriveModes.Reverse` @Value: 0.
---| `GearboxDriveModes.Neutral` @Value: 1.
---| `GearboxDriveModes.Normal` @Value: 2.
---| `GearboxDriveModes.Sport` @Value: 3.
---| `GearboxDriveModes.Track` @Value: 4.
local GearboxDriveModes = {
	Reverse = 0,
	Neutral = 1,
	Normal = 2,
	Sport = 3,
	Track = 4,
}

local gearbox_valve = GearboxDriveModes.Neutral
local gearbox_valve_manual = false

-- Locals - Chassis Driving Modes

local drivemode_comfort = false
local drivemode_sport = false
local drivemode_track = false
local drivemode_race = false

-- Locals - Clutch Control

local clutch_speed_high = 0
local clutch_speed_mid = 0
local clutch_speed_off = 0
local clutch_rpm_bite = 0
local clutch_bitepoint = 0
local clutch_min = 0
local clutch_max = 0
local clutch_on = false
local clutch_off = false

-- Locals - Debug
local ptratio = (car.drivetrainPower * throttle)
local ttratio = (car.drivetrainTorque * throttle)
local speed_mph = speed / 1.60934

------------------------------------------------------------------------------------------------------------------

--[[ Shifting -- old shifting code. Its obsolete now but keep it in case something breaks :>

    local   up = 0 -- constant
    local down = 1 -- constant

	function shift(dir)

		if (dir == up) then
			data.gearUp = true
			data.gearDown = false
		end

		if (dir == down) then
			data.gearUp = false
			data.gearDown = true
		end

	end]]

------------------------------------------------------------------------------------------------------------------

-- Gearing
-- gears table data is automated
local gears = {} -- max speed for each gear (ie; [1]=40, [2]=80 etc)
local calc = {
	speed = 0,
	gear = 0,
	final = phy.finalRatio,
	tire = (car.wheels[1].tyreRadius * 2),
	rpm = car.rpmLimiter,
}
for x = 2, #phy.gearRatios - 1, 1 do
	-- this goes 1=nil, 2-3-4..., nil again ??
	-- Skipping the first and last, the middle should be gears
	-- 2,3,4 = 1,2,3
	calc.gear = (phy.gearRatios[x] or 0)

	-- MPH using tire inches: gear speed = (rpm * diameter * pi) / (final * gear * 1056)
	calc.speed = (calc.rpm * calc.tire * math.pi)
		/ (calc.final * calc.gear * 1056)
		* 39 -- convert tire to meters
		* 1.60934 -- convert from mph to kmh

	gears[x - 1] = calc.speed
end

--for x=1, #gears, 1 do log("Gear "..x..": " .. gears[x] / 1.609) end

-- Helper function: returns a gear's top speed.
-- n = gear number, none or 0 for current
--      Positive returns that gear (5 = gear 5)
--      Negative returns minus current (-2 = current gear -2)
-- t = optional return multiplier
local function _gear(n, t)
	n = n or gear
	if n <= 0 then
		n = gear + n
	end
	if n < 1 then
		n = 1
	end
	t = t or 1
	return gears[n] * t
end

------------------------------------------------------------------------------------------------------------------

local function setGearboxDriveModeNormal()
	gearbox_valve = GearboxDriveModes.Normal
	throttle_mode_normal = true
	ac.debug("Car Gearbox Mode", "Normal")
	ac.debug("Throttle Mode", "Normal")
	--ac.setMessage('Normal mode engaged.')
end

local function setGearboxDriveModeSport()
	gearbox_valve = GearboxDriveModes.Sport
	throttle_mode_sport = true
	ac.debug("Car Gearbox Mode", "Sport")
	ac.debug("Throttle Mode", "Sport")
	--ac.setMessage('Normal mode engaged.')
end

local function setGearboxDriveModeTrack()
	gearbox_valve = GearboxDriveModes.Track
	ac.debug("Car Gearbox Mode", "Track")
	--ac.setMessage('Race mode engaged.')
end

-- Reverse Mode
reverseGearButton:onPressed(function()
	if car.speedKmh < 1 or car.gear == -1 and car.speedKmh < 1 then
		gearbox_valve = GearboxDriveModes.Reverse
	end
end)

-- Neutral Mode
neutralGearButton:onPressed(function()
	if car.speedKmh < 1 or car.speedKmh < 1 and data.requestedGearIndex == 1 then
		gearbox_valve = GearboxDriveModes.Neutral
	end
end)

driveModeButtonDown:onPressed(function()
	gearbox_valve = gearbox_valve - 1

	if gearbox_valve < GearboxDriveModes.Normal then
		gearbox_valve = GearboxDriveModes.Track
	end

	if gearbox_valve == GearboxDriveModes.Normal then
		setGearboxDriveModeNormal()
	elseif gearbox_valve == GearboxDriveModes.Sport then
		setGearboxDriveModeSport()
	elseif gearbox_valve == GearboxDriveModes.Track then
		setGearboxDriveModeTrack()
	end
end)

driveModeButtonUp:onPressed(function()
	gearbox_valve = gearbox_valve + 1

	if gearbox_valve > GearboxDriveModes.Track then
		gearbox_valve = GearboxDriveModes.Normal
	end

	if gearbox_valve == GearboxDriveModes.Normal then
		setGearboxDriveModeNormal()
	elseif gearbox_valve == GearboxDriveModes.Sport then
		setGearboxDriveModeSport()
	elseif gearbox_valve == GearboxDriveModes.Track then
		setGearboxDriveModeTrack()
	end
end)

-- Normal Mode
driveModeButtonMPS[GearboxDriveModes.Normal]:onPressed(function()
	setGearboxDriveModeNormal()
end)

-- Sport Mode
driveModeButtonMPS[GearboxDriveModes.Sport]:onPressed(function()
	setGearboxDriveModeSport()
end)

-- Track Mode
driveModeButtonMPS[GearboxDriveModes.Track]:onPressed(function()
	setGearboxDriveModeTrack()
end)

-- Manual Mode
manualModeButton:onPressed(function()
	if gearbox_valve_manual == true then
		gearbox_valve_manual = false
		ac.debug("Car Gearbox Manual", "No")
		return
	end

	if gearbox_valve ~= GearboxDriveModes.Reverse and gearbox_valve ~= GearboxDriveModes.Neutral then
		gearbox_valve_manual = true
		ac.debug("Car Gearbox Manual", "Yes")
	end
end)

------------------------------------------------------------------------------------------------------------------
function script.update(dt)
	------------------------------------------------------------------------------------------------------------------
	-- Debugging
	bug("! Running", " ")

	gear = data.gear or 0
	speed = data.speedKmh or 0
	rpm = data.rpm or 0
	throttle = data.gas or 0
	braking = data.brake or 0

	-- Remove reverse from gear index (neutral=0, first=1, ...)
	if gear >= 0 then
		gear = gear - 1
	end

	--Debug
	ptratio = (car.drivetrainPower * throttle)
	ttratio = (car.drivetrainTorque * throttle)
	speed_mph = speed / 1.60934
	ac.debug("Car Wheel Power", ptratio)
	ac.debug("Car Wheel Torque", ttratio)
	ac.debug("Car Speed KMH", speed)
	ac.debug("Car Speed MPH", speed_mph)
	ac.debug("Car Engine RPM", rpm)
	ac.debug("Car Throttle", throttle)
	ac.debug("Car Brake", braking)
	ac.debug("Car Gear", car.gear)
	ac.debug("Car Clutch", data.clutch)
	ac.debug("Car Clutch Max", clutch_max)
	ac.debug("Shift Target", target)
	ac.debug("Shift Target Max", target_max)
	ac.debug("Shift Lock", shift_lock)
	--ac.debug("Shift Paddle Lock", shift_paddle_lock)
	ac.debug("LC Timer", lc_counter)
	ac.debug("LC ON", launch_control_on)
	ac.debug("LC Ready", launch_control_ready)
	ac.debug("LC OFF Speed", launch_control_speed)
	ac.debug("AC Auto Shift", ac.autoShift)
	ac.debug("Logic Gear Up", logic_gear_up)
	ac.debug("Logic Gear Dn", logic_gear_dn)
	ac.debug("Logic Allow P.Shift", allow_paddle_shift)
	ac.debug("Logic Shift Lag", shift_lag)

	--Disable (diagnostic)
	--if (true) then return end

	------------------------------------------------------------------------------------------------------------------

	-- Throttle map

	-- normal
	if throttle_mode_normal == true or gearbox_valve == GearboxDriveModes.Reverse then
		if logic_gear_dn == 0 or logic_gear_up == 0 then
			if throttle >= 0 then
				data.gas = 0 + interpolate(0, 0.1, throttle, 0, 0.12)
				if throttle >= 0.1 then
					data.gas = 0 + interpolate(0.1, 0.2, throttle, 0.12, 0.25)
					if throttle >= 0.2 then
						data.gas = 0 + interpolate(0.2, 0.3, throttle, 0.25, 0.35)
						if throttle >= 0.3 then
							data.gas = 0 + interpolate(0.3, 0.4, throttle, 0.35, 0.45)
							if throttle >= 0.4 then
								data.gas = 0 + interpolate(0.4, 0.5, throttle, 0.45, 0.52)
								if throttle >= 0.5 then
									data.gas = 0 + interpolate(0.5, 0.6, throttle, 0.52, 0.6)
									if throttle >= 0.6 then
										data.gas = 0 + interpolate(0.6, 0.7, throttle, 0.6, 0.7)
										if throttle >= 0.7 then
											data.gas = 0 + interpolate(0.7, 0.8, throttle, 0.7, 0.8)
											if throttle >= 0.8 then
												data.gas = 0 + interpolate(0.8, 0.9, throttle, 0.8, 0.9)
												if throttle >= 0.9 then
													data.gas = 0 + interpolate(0.9, 1, throttle, 0.9, 1)
												end
											end
										end
									end
								end
							end
						end
					end
				end
			end
		elseif logic_gear_dn > 0 or logic_gear_up > 0 then
			throttle = throttle
		end
		-- sport and race
	elseif throttle_mode_sport == true or throttle_mode_race == true then
		if logic_gear_dn == 0 or logic_gear_up == 0 then
			if throttle >= 0 then
				data.gas = 0 + interpolate(0, 0.1, throttle, 0, 0.18)
				if throttle >= 0.1 then
					data.gas = 0 + interpolate(0.1, 0.2, throttle, 0.18, 0.35)
					if throttle >= 0.2 then
						data.gas = 0 + interpolate(0.2, 0.3, throttle, 0.35, 0.52)
						if throttle >= 0.3 then
							data.gas = 0 + interpolate(0.3, 0.4, throttle, 0.52, 0.6)
							if throttle >= 0.4 then
								data.gas = 0 + interpolate(0.4, 0.5, throttle, 0.6, 0.68)
								if throttle >= 0.5 then
									data.gas = 0 + interpolate(0.5, 0.6, throttle, 0.68, 0.75)
									if throttle >= 0.6 then
										data.gas = 0 + interpolate(0.6, 0.7, throttle, 0.75, 0.8)
										if throttle >= 0.7 then
											data.gas = 0 + interpolate(0.7, 0.8, throttle, 0.8, 0.85)
											if throttle >= 0.8 then
												data.gas = 0 + interpolate(0.8, 0.9, throttle, 0.85, 0.93)
												if throttle >= 0.9 then
													data.gas = 0 + interpolate(0.9, 1, throttle, 0.93, 1)
												end
											end
										end
									end
								end
							end
						end
					end
				end
			end
		elseif logic_gear_dn > 0 or logic_gear_up > 0 then
			throttle = throttle
		end
	end

	------------------------------------------------------------------------------------------------------------------

	-- Throttle Cut And Blip -- new code to cooperate with new clutch control

	if logic_gear_up > 0 then
		if logic_gear_up > 0.193 then
			data.gas = throttle * interpolate(0, 1, throttle, 1, 0.45) * interpolate(1, 110, car.speedKmh, 0.75, 1)
		elseif logic_gear_up < 0.193 then
			data.gas = throttle
				* interpolate(0, 0.193, logic_gear_up, 1, 0.45)
				* interpolate(1, 110, car.speedKmh, 0.1, 1)
		else
			data.gas = throttle
		end
	end

	if logic_gear_dn > 0 and throttle == 0 then
		if logic_gear_dn > 0.353 then
			data.gas = 1 * interpolate(1000, 6500, car.rpm, 0.5, 0.45) * interpolate(5, 30, car.speedKmh, 0.05, 1)
		elseif logic_gear_dn < 0.353 then
			data.gas = 1
				* interpolate(0, 0.353, logic_gear_dn, 0, 1)
				* interpolate(1000, 6500, car.rpm, 0.5, 0.45)
				* interpolate(5, 30, car.speedKmh, 0.05, 1)
		end
	elseif logic_gear_dn > 0 and throttle > 0 then
		if logic_gear_dn > 0.353 then
			data.gas = throttle * interpolate(1000, 6500, car.rpm, 0.6, 0.85) * interpolate(5, 30, car.speedKmh, 0.2, 1)
		elseif logic_gear_dn < 0.353 then
			data.gas = throttle
				* interpolate(0, 0.353, logic_gear_dn, 2, 1)
				* interpolate(1000, 6500, car.rpm, 0.6, 0.85)
				* interpolate(5, 30, car.speedKmh, 0.2, 1)
		end
	end

	------------------------------------------------------------------------------------------------------------------

	-- Target

	local function _target(change)
		change = change or 0
		target = target + change
		target = math.clamp(target, 0, 100) -- min/max values for now
		return target
	end

	-- drop rate
	--_target(-0.025)
	local fast_drop = interpolate(1000, 6500, rpm, 1, 0.0)
	--_target((-0.05 * fast_drop))

	--target limiting
	if gearbox_valve == GearboxDriveModes.Normal or gearbox_valve == GearboxDriveModes.Reverse then
		if logic_gear_dn == 0 or logic_gear_up == 0 then
			if throttle >= 0 then
				target_max = 0 + interpolate(0, 0.1, throttle, 10, 10)
				if throttle >= 0.1 then
					target_max = 0 + interpolate(0.1, 0.2, throttle, 10, 15)
					if throttle >= 0.2 then
						target_max = 0 + interpolate(0.2, 0.3, throttle, 15, 20)
						if throttle >= 0.3 then
							target_max = 0 + interpolate(0.3, 0.4, throttle, 20, 25)
							if throttle >= 0.4 then
								target_max = 0 + interpolate(0.4, 0.5, throttle, 25, 30)
								if throttle >= 0.5 then
									target_max = 0 + interpolate(0.5, 0.6, throttle, 30, 45)
									if throttle >= 0.6 then
										target_max = 0 + interpolate(0.6, 0.7, throttle, 45, 60)
										if throttle >= 0.7 then
											target_max = 0 + interpolate(0.7, 0.8, throttle, 60, 75)
											if throttle >= 0.8 then
												target_max = 0 + interpolate(0.8, 0.9, throttle, 75, 90)
												if throttle >= 0.9 then
													target_max = 0 + interpolate(0.9, 1, throttle, 90, 100)
												end
											end
										end
									end
								end
							end
						end
					end
				end
			end
		elseif logic_gear_dn > 0 or logic_gear_up > 0 then
			throttle = throttle
		end
	elseif gearbox_valve == GearboxDriveModes.Sport then
		if logic_gear_dn == 0 or logic_gear_up == 0 then
			if throttle >= 0 then
				target_max = 0 + interpolate(0, 0.1, throttle, 50, 55)
				if throttle >= 0.1 then
					target_max = 0 + interpolate(0.1, 0.2, throttle, 55, 60)
					if throttle >= 0.2 then
						target_max = 0 + interpolate(0.2, 0.3, throttle, 60, 65)
						if throttle >= 0.3 then
							target_max = 0 + interpolate(0.3, 0.4, throttle, 65, 70)
							if throttle >= 0.4 then
								target_max = 0 + interpolate(0.4, 0.5, throttle, 70, 75)
								if throttle >= 0.5 then
									target_max = 0 + interpolate(0.5, 0.6, throttle, 75, 80)
									if throttle >= 0.6 then
										target_max = 0 + interpolate(0.6, 0.7, throttle, 90, 85)
										if throttle >= 0.7 then
											target_max = 0 + interpolate(0.7, 0.8, throttle, 95, 90)
											if throttle >= 0.8 then
												target_max = 0 + interpolate(0.8, 0.9, throttle, 90, 95)
												if throttle >= 0.9 then
													target_max = 0 + interpolate(0.9, 1, throttle, 95, 100)
												end
											end
										end
									end
								end
							end
						end
					end
				end
			end
		elseif logic_gear_dn > 0 or logic_gear_up > 0 then
			throttle = throttle
		end
	end

	if target > target_max and throttle > 0 then
		_target((-0.05 * interpolate(0, 1, throttle, 4, 6)) * fast_drop)
	elseif target > target_max and throttle == 0 then
		_target((-0.05 * interpolate(0, 1, throttle, 0.75, 0.75)) * fast_drop)
	end

	if braking > 0.05 and car.speedKmh > 5 then
		_target(0.2 * interpolate(0.25, 1, braking, 0, 0.25))
		target_max = 100 * interpolate(0.25, 1, braking, 0, 1)
	end

	if gearbox_valve == GearboxDriveModes.Reverse then
		target = math.clamp(target, 100, 100)
		target_max = math.clamp(target, 100, 100)
	elseif gearbox_valve == GearboxDriveModes.Neutral then
		target = math.clamp(target, 100, 100)
		target_max = math.clamp(target, 100, 100)
	elseif gearbox_valve == GearboxDriveModes.Normal then
		target = math.clamp(target, 10, 100)
		target_max = math.clamp(target, 10, 100)
	elseif gearbox_valve == GearboxDriveModes.Sport then
		target = math.clamp(target, 50, 100)
		target_max = math.clamp(target, 50, 100)
	elseif gearbox_valve == GearboxDriveModes.Track then
		target = math.clamp(target, 95, 100)
		target_max = math.clamp(target, 95, 100)
	elseif gearbox_valve == GearboxDriveModes.Manual then
		target = math.clamp(target, 0, 100)
		target_max = math.clamp(target, 0, 100)
	end

	-- Throttle
	_target(interpolate(0.0, 0.75, throttle, 0.0, 0.25)) --low
	_target(interpolate(0.75, 1, throttle, 0.0, 0.6)) --high

	if shift_paddle_lock > 0 and target_max >= 0 then
		target_max = (car.rpm / car.rpmLimiter) * 100
		if target_max <= 0 then
			target_max = 0
		end
	end

	if shift_paddle_lock > 0 and target_max < 100 then
		target_max = (car.rpm / car.rpmLimiter) * 100
		if target_max >= 100 then
			target_max = 100
		end
	end

	------------------------------------------------------------------------------------------------------------------

	-- Offset And Limiter

	-- Offset is the speed parameter between shifts
	local offset_up = 0.8
	local offset_down = 0.8

	-- Adjust offsets according to the performance target
	offset_up = interpolate(0, 100, target, offset_up, 0)

	offset_down = offset_up -- Tames downshift at lower target
		+ interpolate(0, 100, target, _gear(-1, 0) / 100, 0)

	-- Mostly needed when offset is 0 (racing)
	local limiter = 0 / 100

	-- Use this to tweak shift point for each gear
	-- Limiter has to be negative on higher gears bcuz the higher the gear, the lower shift point is if limiter is set to static value

	if gearbox_valve == GearboxDriveModes.Normal then
		if car.gear == 1 then
			limiter = 6 / 100
		elseif car.gear > 1 then
			limiter = (5 - car.gear / 2) / 100
		end
	end

	if gearbox_valve == GearboxDriveModes.Sport or gearbox_valve == GearboxDriveModes.Track then
		if car.gear == 1 then
			limiter = 8 / 100
		elseif car.gear > 1 then
			limiter = (5 - car.gear / 2) / 100
		end
	end

	-- Downshift lockout (prefers to stay in current gear than downshift)
	-- Without this, mashing on the throttle will drop a gear too short
	-- This code works. Don't touch

	if throttle > 0.85 and target > 75 and (speed < _gear(-1) * 0.7) and ac.autoShift == true then
		shift_lock = 0
		shift_paddle_lock = 0
		if logic_gear_dn > 0 then
			calc.speed = calc.speed * 2
			--offset_down = _gear(-1)
			kickdown = true
			ac.debug("Logic Kickdown", "YES")
		end
	else
		shift_lock = shift_lock
		shift_paddle_lock = shift_paddle_lock
		kickdown = false
		ac.debug("Logic Kickdown", "NO")
	end

	------------------------------------------------------------------------------------------------------------------

	-- Shifting logic

	-- Shift up
	if
		(
				speed
				> _gear(0) -- current gear speed
					- (_gear(0, limiter)) -- % of current gear speed
					- (_gear(0, offset_up)) -- offset of current gear speed
			)
			and shift_lock <= 0
			and car.gear <= 6
			and ac.autoShift == true
		or data.gearUp == true and allow_paddle_shift == true
	then
		data.gearUp = true
	elseif shift_lock > 0 or allow_paddle_shift == false then
		data.gearUp = false
	end

	-- Shift down
	if
		(
				speed
				< _gear(-1) -- 1 lower gear speed
					- _gear(-1, limiter) -- % of lower gear speed
					- _gear(-1, offset_down) -- offset of lower gear speed
			)
			and target >= (throttle * 100)
			and shift_lock <= 0
			and car.gear >= 2
			and ac.autoShift == true
		or data.gearDown == true and allow_paddle_shift == true
	then
		data.gearDown = true
	elseif shift_lock > 0 or allow_paddle_shift == false then
		data.gearDown = false
	end

	------------------------------------------------------------------------------------------------------------------

	-- Shifting Locks

	if data.gearUp or data.gearDown then
		shift_lock = 1 * (interpolate(0, 1, throttle, 4, 1) * interpolate(0, 1, braking, 1, 0.5)) - dt
		if shift_lock < 0.1 and data.gearUp then
			shift_lock = 0.1
		else
			shift_lock = shift_lock - dt
		end
	else
		shift_lock = shift_lock - dt
		if kickdown == true or car.speedKmh < 5 then
			shift_lock = 0
		else
			shift_lock = shift_lock - dt
		end
	end

	if shift_lock <= 0 then
		shift_lock = 0
	else
		shift_lock = shift_lock
	end

	if shift_lock == 0 then
		allow_paddle_shift = true
	else
		allow_paddle_shift = false
	end

	if ac.isControllerGearUpPressed() then
		shift_lag = 0.25 - dt
	elseif shift_lag < 0.25 then
		shift_lag = shift_lag - dt
	elseif shift_lag <= 0 then
		shift_lag = 0.25
	end

	------------------------------------------------------------------------------------------------------------------

	-- Shifting Counters

	if data.gearUp == true then
		logic_gear_up = 0.203 - dt -- vanilla clutch time on upshift -- always add 0.003, don't ask why
	else
		logic_gear_up = logic_gear_up - dt
	end
	if logic_gear_up < 0 then
		logic_gear_up = 0
	end

	if data.gearDown == true then
		logic_gear_dn = 0.403 - dt -- vanilla clutch time on downshift -- always add 0.003, don't ask why
	else
		logic_gear_dn = logic_gear_dn - dt
	end
	if logic_gear_dn < 0 then
		logic_gear_dn = 0
	end

	------------------------------------------------------------------------------------------------------------------

	-- Gearbox Driving Modes

	if gearbox_valve_manual == true then
		ac.autoShift = false
		if car.gear < 1 then
			data.requestedGearIndex = (data.gear - data.gear) + 2
		end
		-- use this if irl car doesn't let engine rev up to the limiter
		--[[if (car.rpm > (car.rpmLimiter - 50)) and car.gear >= 1 then
				ac.autoShift = true
			end]]
		if (car.rpm < 1100) and car.gear >= 2 then
			ac.autoShift = true
		end
	elseif gearbox_valve == GearboxDriveModes.Track then
		ac.autoShift = true
		if car.gear < 1 then
			data.requestedGearIndex = (data.gear - data.gear) + 2
		end
	elseif gearbox_valve == GearboxDriveModes.Sport then
		ac.autoShift = true
		if car.gear < 1 then
			data.requestedGearIndex = (data.gear - data.gear) + 2
		end
	elseif gearbox_valve == GearboxDriveModes.Normal then
		ac.autoShift = true
		if car.gear < 1 then
			data.requestedGearIndex = (data.gear - data.gear) + 2
		end
	elseif gearbox_valve == GearboxDriveModes.Neutral then
		ac.autoShift = true
		data.gas = throttle * interpolate(1000, 4500, car.rpm, 1, 0.0)
		ac.isShifterSupported = 1
		data.requestedGearIndex = 1
		if not car.gear == 0 then
			data.requestedGearIndex = (data.gear - data.gear) + 2
		end
		if car.speedKmh >= 0 and logic_gear_dn > 0 and logic_gear_up > 0 then
			data.gas = throttle * interpolate(1000, 4500, car.rpm, 1, 1)
		end
		--else
		--data.rpm = data.rpm * 0
	elseif gearbox_valve == GearboxDriveModes.Reverse then
		ac.autoShift = false
		target = math.clamp(target, 100, 100)
		--ac.isShifterSupported = 1
		data.requestedGearIndex = 0

		if ac.isControllerGearUpPressed() or not ac.isControllerGearUpPressed() then
			data.gearUp = false
		end
		if ac.isControllerGearDownPressed() or not ac.isControllerGearDownPressed() then
			data.gearDown = false
		end
	end

	--[[if data.requestedGearIndex == 0 then
			data.gas = throttle
		end

		if data.requestedGearIndex == 1 and car.gear == 0 then
			--data.gear = 1
			data.gas = throttle * interpolate(1000,4500, car.rpm, 1, 0.0)
			--data.isShifterSupported = 1
			elseif data.requestedGearIndex < 1 then
				data.isShifterSupported = 1
		end

		if data.requestedGearIndex == 2 then
			data.requestedGearIndex = data.requestedGearIndex - 1
			data.gas = throttle * interpolate(1000,4500, car.rpm, 1, 0.0)
			--data.isShifterSupported = 0
			if car.speedKmh < 1 and ac.isControllerGearDownPressed() and ac.isControllerGearUpPressed() then
				data.gas = throttle * interpolate(1000,4500, car.rpm, 1, 1)
			end
		end]]

	--[[if data.requestedGearIndex == 3 then
			if car.gear <= 0 then
				data.isShifterSupported = 0
				data.requestedGearIndex = 2
				elseif car.gear >= 1 then
					data.isShifterSupported = 0
					data.requestedGearIndex = data.requestedGearIndex - 1
				elseif car.gear >= 2 then
					data.isShifterSupported = 0
					data.requestedGearIndex = data.requestedGearIndex + 1
			end
		end]]

	--[[if car.gear == 1 and data.requestedGearIndex == 3 then
			data.isShifterSupported = 0
			data.requestedGearIndex = data.requestedGearIndex - 1
			elseif car.gear == 2 and data.requestedGearIndex == 3 then
				data.isShifterSupported = 0
				data.requestedGearIndex = data.requestedGearIndex
			elseif car.gear == 3 and data.requestedGearIndex == 3 then
				data.isShifterSupported = 0
				data.requestedGearIndex = data.requestedGearIndex + 1
			elseif car.gear == 4 and data.requestedGearIndex == 3 then
				data.isShifterSupported = 0
				data.requestedGearIndex = data.requestedGearIndex + 2
			elseif car.gear == 5 and data.requestedGearIndex == 3 then
				data.isShifterSupported = 0
				data.requestedGearIndex = data.requestedGearIndex + 3
			elseif car.gear == 6 and data.requestedGearIndex == 3 then
				data.isShifterSupported = 0
				data.requestedGearIndex = data.requestedGearIndex + 4
			elseif car.gear == 7 and data.requestedGearIndex == 3 then
				data.isShifterSupported = 0
				data.requestedGearIndex = data.requestedGearIndex + 5
		end]]

	--[[if data.requestedGearIndex == 3 and data.requestedGearIndex > 0 then
			if car.gear >= 0 then
			data.isShifterSupported = 0
			data.requestedGearIndex = (data.requestedGearIndex - data.requestedGearIndex) + 2
			end
		end]]

	--[[if car.extraB then
			if data.gearUp == true then
				gear_up_time = 250
				else
					gear_up_time = 10
			end
		end]]

	------------------------------------------------------------------------------------------------------------------

	-- Chassis Driving Modes

	------------------------------------------------------------------------------------------------------------------

	-- Launch Control

	if launchControlActiveButton:down() and car.speedKmh < 1 and car.gear == 1 and car.tractionControlModes > 0 then
		lc_counter = lc_counter + dt
	else
		lc_counter = 0
	end

	if lc_counter >= 1 then
		launch_control_on = 1
		ac.setMessage(
			"Launch Control is ON. Push brake and gas pedals.",
			"You can use the Launch Control Adjustment buttons to change launch RPMs."
		)
	elseif car.speedKmh >= launch_control_speed then
		launch_control_on = 0
		launch_control_speed = 38
		launch_control_rpm = 4000
	end

	if launch_control_on == 1 and braking > 0.75 and car.gear == 1 then
		launch_control_ready = 1
	else
		launch_control_ready = 0
	end

	if launch_control_on == 1 and throttle > 0 and data.rpm >= launch_control_rpm then
		data.rpm = data.rpm - ((data.rpm - launch_control_rpm) + 100)
		if throttle == 1 and car.speedKmh >= 0.1 then
			data.rpm = launch_control_rpm
		else
			data.rpm = data.rpm
		end
	end

	if launch_control_ready == 1 then
		if launchControlUpButton:pressed() then
			launch_control_rpm = launch_control_rpm + 100
			launch_control_speed = launch_control_speed + 0.9
			ac.setSystemMessage("Launch Control", "RPM: " .. launch_control_rpm .. " | Speed: " .. launch_control_speed)
		elseif launch_control_rpm > 5500 and launch_control_speed > 52 then
			launch_control_rpm = 5500
			launch_control_speed = 52
		end
		if launchControlDownButton:pressed() then
			launch_control_rpm = launch_control_rpm - 100
			launch_control_speed = launch_control_speed - 0.9
			ac.setSystemMessage("Launch Control", "RPM: " .. launch_control_rpm .. " | Speed: " .. launch_control_speed)
		elseif launch_control_rpm < 2500 and launch_control_speed < 25 then
			launch_control_rpm = 2500
			launch_control_speed = 25
		end
	end

	if car.speedKmh < 1 and data.gear == 2 and launch_control_on > 0 then
		if braking >= 0.75 and throttle > 0 then
			data.brake = 1
			if car.turboBoosts[0] > 0.72 then
				ac.setMessage("Launch Control is ready. Release brake pedal to start.")
			end
		end
	end

	if launch_control_ready == 1 then
		ac.setGearsFinalRatio(stock_final_drive - stock_final_drive)
	elseif launch_control_ready == 0 then
		ac.setGearsFinalRatio(stock_final_drive)
	end

	------------------------------------------------------------------------------------------------------------------

	-- Handbrake AutoHold - used in cars with electric handbrake

	if car.speedKmh < 1 then
		data.handbrake = 0 + interpolate(1, 2, car.speedKmh, 0.5, 0)
	end

	if car.speedKmh > 1 and data.handbrake > 0 then
		data.brake = 0.25
		data.handbrake = 0.95
	end

	------------------------------------------------------------------------------------------------------------------

	-- Clutch Control - test

	--clutch_rpm_bite = 1000 * interpolate(0,1, throttle, 1.5, 3.5)
	--clutch_speed_off = clutch_speed_bite + (20 * interpolate(0,1, throttle, 0.25, 1))
	clutch_speed_bite = 1 * interpolate(0, 1, throttle, 15, 40)
	clutch_min = 0.075
	clutch_max = (0.50 + (data.gas * 0.4999)) - (logic_gear_up * 0.5)

	if car.gear == -1 or car.gear >= 1 then
		if throttle == 0 then
			data.clutch = clutch_max * interpolate(750, 1250, car.rpm, 0.0, 1)
		elseif throttle > 0 then
			if car.speedKmh < clutch_speed_bite then
				data.clutch = 1 * interpolate(1000, 3000, car.rpm, 0.0, 1)
			elseif car.speedKmh > clutch_speed_bite then
				data.clutch = data.clutch
			end
		end
	elseif car.gear == 0 then
		data.clutch = 0
	end

	if car.rpm < 1000 then
		if car.gear == 1 or car.gear == -1 then
			if braking > 0 and car.speedKmh < 1 then
				data.clutch = 0
				clutch_min = 0
			end
		end
	end

	if data.clutch < clutch_min then
		data.clutch = clutch_min
	elseif data.clutch > clutch_max then
		data.clutch = clutch_max
	end

	if car.rpm < 740 and car.gear ~= 0 then
		data.gas = 1 * interpolate(550, 740, car.rpm, 0.5, 0)
	end

	--return math.applyLag(clutch_max, 0.5, dt)

	--[[ Clutch control for semi-automatic, dual clutch and other gearboxes which don't use hydrokinetic clutch

	if logic_gear_up ~= 0 then
		if logic_gear_up > 0.173 then
			data.clutch = 0
			elseif logic_gear_up < 0.173 then
				data.clutch = 1 * interpolate(0, 0.173, logic_gear_up, 0.5, 0)
				elseif logic_gear_up == 0 then
					data.clutch = data.clutch
		end
	end

	if logic_gear_dn ~= 0 then
		if logic_gear_dn > 0.303 then
			data.clutch = 0
			elseif logic_gear_dn < 0.303 then
				data.clutch = 1 * interpolate(0, 0.303, logic_gear_dn, 0.5, 0)
				elseif logic_gear_dn == 0 then
					data.clutch = data.clutch
		end
	end]]

	------------------------------------------------------------------------------------------------------------------

	--[[ Mechanical Throttle Body -- used for older cars -- by Stereo

	local data = ac.accessCarPhysics()
	data.enforceCustomInputScheme = true
	user_gas = data.gas
	-- remap throttle pedal to behave as a mechanical throttle rather than drive by wire
	data.gas = throttle_module(data.gas, data.rpm)

	function throttle_module(gas, rpm)
	-- convert throttle travel to area of open throttle
	local air_size = 1.0 - math.cos(gas * math.pi/2.0)
	-- make part throttle more effective below max rpm
	proportion = math.clamp(max_rpm / rpm, 1, 8) -- clamp how steeply rpm can rise
	prop_gas = math.min(proportion*air_size, 0.8+0.2*air_size)
	-- ac.debug("prop gas",prop_gas)
	return prop_gas
	end]]

	------------------------------------------------------------------------------------------------------------------

	--[[ Ignition and Engine Starter -- by CheesyManiac

	local carState = {
		ignition = false,
		cranking = false,
		crankAllowed = true
	}

	local carInfo = {
		0.6, --starter overrun time in seconds
		ac.INIConfig.carData(0, 'engine.ini'):get('ENGINE_DATA', 'MINIMUM', 900) --engine idle value
	}

	ac.setEngineStalling(true)
		local engineStartRPM = 1300
		local crankTime = 0
		local cd = 0
		local CARPM = 0
		local tmp = 0
		local carRPM = 0

	function script.update(dt)
		CAR = ac.accessCarPhysics()
		carInputs = {
			ignition = car.extraB,
			cranking = car.extraC,
			clutch = CAR.clutch
		}

		--local dt because csp aint got nothing
		cd = cd + 0.003
		----------------------------

		if carInputs.cranking and carState.crankAllowed and CAR.rpm < carInfo[2] then
			crankTime = cd + carInfo[1]
		end

		--engage the starter, allow a small overrun
		if cd <= crankTime and carInputs.ignition then
			carState.cranking = true
		else
			carState.cranking = false
		end

		--stop the engine
		if not carInputs.ignition then
			carState.crankAllowed = true
			carRPM = math.applyLag(carRPM, 0, 0.97, 0.003)
		if carRPM < 10 then
			  carRPM = 0 --otherwise it will slowly drop to 0 forever
		end
			ac.setEngineRPM(carRPM)
		else
			carRPM = CAR.rpm
		end

		--engage the starter motor
		if carState.cranking then
			carRPM = math.applyLag(carRPM, engineStartRPM, 0.92, 0.003)
			ac.setEngineRPM(carRPM)
		else
			carRPM = CAR.rpm
		end
	end]]

	------------------------------------------------------------------------------------------------------------------

	--[[ misc and other stuff i dunno


		--local data = ac.accessCarPhysics()
			if data.requestedGearIndex == 1 then
				data.isShifterSupported = 1
			end

			if data.requestedGearIndex == 1 then
				data.gas = 0
			end

		--if  data.steer >=  0 then
			SlipCorr = (-1 * cSlipF)
		else
			SlipCorr = cSlipF
		end

		if car.isAIControlled then
			return    nil
		end]]

	------------------------------------------------------------------------------------------------------------------
end
