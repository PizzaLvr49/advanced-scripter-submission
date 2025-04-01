local AnalyticsService = game:GetService("AnalyticsService")
local MarketplaceService = game:GetService("MarketplaceService")
local ProfileService = require(script.Parent.ProfileService)
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Economy = {}

-- Constants for configuration 
local profileStoreName = "dev"
local profileTemplate = {
	currencies = {},
	processedReceipts = {},
	lastReceiptCleanup = 0
}
local receiptRetentionDays = 30 -- How long to keep processed receipts
local autoSaveInterval = 300 -- 5 minutes
local maxTransactionRetry = 3
local transactionRetryDelay = 0.5

-- Currency type definitions
export type CurrencyData = {
	displayName: string,
	abbreviation: string,
	saveKey: string,
	canBePurchased: boolean,
	canBeEarned: boolean,
	exchangeRateToRobux: number,
	defaultValue: number,
	minValue: number, -- Added min value
	maxValue: number, -- Added max value
	purchaseIDs: { [number]: number } -- Amount of currency: Purchase ID
}

export type Currency = CurrencyData & {
	SetValue: (Currency, playerID: number, value: number) -> (boolean, string?),
	GetValue: (Currency, playerID: number) -> (number, boolean),
	IncrementValue: (Currency, playerID: number, amount: number) -> (boolean, string?),
	DecrementValue: (Currency, playerID: number, amount: number) -> (boolean, string?),
	TransferValue: (Currency, fromPlayerID: number, toPlayerID: number, amount: number) -> (boolean, string?)
}

export type TransactionInfo = {
	transactionId: string,
	timestamp: number,
	playerID: number,
	currencyKey: string,
	previousValue: number,
	newValue: number,
	changeAmount: number,
	reason: string?
}

-- Define currencies with complete configurations ( for objects)
local Currencies = {
	Cash = {
		displayName = "Cash",
		abbreviation = "$",
		saveKey = "Cash",
		canBePurchased = true,
		canBeEarned = true,
		exchangeRateToRobux = 10_000,
		defaultValue = 1000,
		minValue = 0,
		maxValue = 1_000_000_000, -- 1 billion max
		purchaseIDs = {
			[100] = { SKU = "100 Cash", ID = 3254661193 },  -- 1 Robux
			[10000] = { SKU = "10k Cash", ID = 3254661195 },  -- 300 Robux
			[100000] = { SKU = "100k Cash", ID = 3254661196 },  -- 1000 Robux
			[1000000] = { SKU = "1M Cash", ID = 3254661198 },  -- 5000 Robux
		}
	},
	Gems = {
		displayName = "Gems",
		abbreviation = "💎",
		saveKey = "Gems",
		canBePurchased = true,
		canBeEarned = false,
		exchangeRateToRobux = 100,
		defaultValue = 100,
		minValue = 0,
		maxValue = 1_000_000, -- 1 million max
		purchaseIDs = {}
	}
}

-- Setup ProfileService with a complete template
local ProfileStore = ProfileService.GetProfileStore(
	profileStoreName,
	profileTemplate
)

local profiles = {}
local transactionLocks = {}
local pendingTransactions = {}
local receiptProcessingMap = {}

local developerProductMapping = {}
do
	for currencyName, currencyData in pairs(Currencies) do
		if currencyData.purchaseIDs then
			for amount, productId in pairs(currencyData.purchaseIDs) do
				developerProductMapping[productId.ID] = { 
					currencyName = currencyName,
					currencyData = currencyData, 
					amount = amount 
				}
			end
		end
	end
end

-- Utility functions 
local function isValidNumber(value)
	return type(value) == "number" and not (value ~= value) -- Check for NaN
end

local function generateTransactionID()
	return HttpService:GenerateGUID(false)
end

local function logTransaction(transactionInfo)
	-- Determine the flow type based on whether currency is being added or removed
	local flowType = transactionInfo.changeAmount >= 0 
		and Enum.AnalyticsEconomyFlowType.Source 
		or Enum.AnalyticsEconomyFlowType.Sink

	-- Use the provided transaction type or Default if not specified
	local transactionType = transactionInfo.transactionType or Enum.AnalyticsEconomyTransactionType.Default
	
	local player = Players:GetPlayerByUserId(transactionInfo.playerID)

	if RunService:IsStudio() then
		local playerName = player and player.Name or "Unknown Player"

		local logMessage = string.format(
			"[TRANSACTION] Player: %s | Type: %s | Flow: %s | Currency: %s | Change: %+d | New Balance: %d | Description: %s",
			playerName,
			transactionType.Name,  -- Use Name for display only
			flowType.Name,        -- Use Name for display only
			transactionInfo.currencyKey,
			transactionInfo.changeAmount,
			transactionInfo.newValue,
			transactionInfo.reason
		)

		print(logMessage)
	end

	-- Use actual enum values when calling the API
	AnalyticsService:LogEconomyEvent(
		player,
		flowType,                 -- Flow type: Source or Sink
		transactionInfo.currencyKey,
		math.abs(transactionInfo.changeAmount),  -- Use absolute value as the API expects
		transactionInfo.newValue,
		transactionType.Name,          -- Transaction type: Gameplay, Shop, etc.
		transactionInfo.reason
	)
end

-- Profile Management
local function cleanupOldReceipts(profile)
	if not profile or not profile.Data then return end

	local now = DateTime.now().UnixTimestampMillis * 1000
	if now - (profile.Data.lastReceiptCleanup or 0) < 86400 then return end -- Only run once per day

	local cutoffTime = now - (receiptRetentionDays * 86400)
	local receiptsRemoved = 0

	for receiptId, timestamp in pairs(profile.Data.processedReceipts) do
		if timestamp < cutoffTime then
			profile.Data.processedReceipts[receiptId] = nil
			receiptsRemoved = receiptsRemoved + 1
		end
	end

	profile.Data.lastReceiptCleanup = now

	if receiptsRemoved > 0 and RunService:IsStudio() then
		print("[Economy] Cleaned up " .. receiptsRemoved .. " old receipts for player profile")
	end
end

local function safeGetProfile(playerID)
	local profile = profiles[playerID]
	if not profile then return nil, "Profile not loaded" end
	if not profile.Data then return nil, "Profile data corrupted" end

	-- Ensure currency table exists
	if not profile.Data.currencies then
		profile.Data.currencies = {}
	end

	return profile, nil
end

local function safeProfileOperation(playerID, callback)
	-- This function encapsulates safe profile operations with proper error handling
	local profile, errorMsg = safeGetProfile(playerID)
	if not profile then
		return false, errorMsg
	end

	local success, result = pcall(callback, profile)
	if not success then
		warn("[Economy] Profile operation failed: " .. tostring(result))
		return false, "Internal error"
	end

	return true, result
end

local function scheduleAutoSave()
	while true do
		task.wait(autoSaveInterval)
		for playerID, profile in pairs(profiles) do
			if profile and profile.Data then
				-- Don't yield the thread, just spawn the save
				task.spawn(function()
					local success, err = pcall(function()
						profile:Save()
					end)
					if not success and RunService:IsStudio() then
						warn("[Economy] Auto-save failed for player " .. playerID .. ": " .. tostring(err))
					end
				end)
			end
		end
	end
end

-- Initialize player profile on join with improved error handling ( for event handlers)
local function PlayerAdded(player)
	local playerID = player.UserId

	-- If profile is already loaded, don't load it again
	if profiles[playerID] then
		warn("[Economy] Profile already loaded for player " .. playerID)
		return
	end

	-- Set up a loading lock to prevent duplicate loads
	if transactionLocks[playerID] then
		warn("[Economy] Profile is already being loaded for player " .. playerID)
		return
	end

	transactionLocks[playerID] = true

	local profile
	local success, errorMsg = pcall(function()
		profile = ProfileStore:LoadProfileAsync("Player_" .. playerID)
	end)

	-- Release the loading lock
	transactionLocks[playerID] = nil

	if not success then
		warn("[Economy] Failed to load profile for player " .. playerID .. ": " .. tostring(errorMsg))
		if player:IsDescendantOf(Players) then
			player:Kick("Failed to load your data. Please rejoin.")
		end
		return
	end

	if profile ~= nil then
		profile:AddUserId(playerID) -- GDPR compliance
		profile:Reconcile() -- Fill in missing data with template

		if player:IsDescendantOf(Players) then
			profiles[playerID] = profile

			-- Set up profile release on leave
			profile:ListenToRelease(function()
				profiles[playerID] = nil
				-- If the player is still in game, kick them
				if player:IsDescendantOf(Players) then
					player:Kick("Your data was loaded on another server. Please rejoin.")
				end
			end)

			-- Clean up old receipts
			cleanupOldReceipts(profile)
		else
			-- Player left before profile loaded
			profile:Release()
		end
	else
		-- This happens if the profile is locked (being used by another server)
		if player:IsDescendantOf(Players) then
			player:Kick("Your data is currently in use on another server. Please try again later.")
		end
	end
end

local function PlayerRemoving(player)
	local profile = profiles[player.UserId]
	if profile then
		-- Clean up any pending transactions for this player
		if pendingTransactions[player.UserId] then
			pendingTransactions[player.UserId] = nil
		end

		-- Save before releasing
		pcall(function()
			profile:Save()
		end)

		profile:Release()
		profiles[player.UserId] = nil
	end

	-- Clean up transaction locks
	transactionLocks[player.UserId] = nil
end

-- Currency Functions
local function InitializeCurrency(currencyName, currencyData)
	--  for methods for variables and fields

	-- Get the current value with validation
	function currencyData:GetValue(playerID)
		local success, result = safeProfileOperation(playerID, function(profile)
			local value = profile.Data.currencies[self.saveKey]

			-- Initialize if missing
			if value == nil then
				value = self.defaultValue
				profile.Data.currencies[self.saveKey] = value
			end

			-- Validate the value
			if not isValidNumber(value) then
				warn("[Economy] Invalid currency value for " .. playerID .. ", " .. self.saveKey .. ": " .. tostring(value))
				value = self.defaultValue
				profile.Data.currencies[self.saveKey] = value
			end

			-- Clamp to valid range
			value = math.clamp(value, self.minValue, self.maxValue)
			profile.Data.currencies[self.saveKey] = value

			return value
		end)

		return success and result or self.defaultValue, success
	end

	-- Update SetValue to use valid transaction types
	function currencyData:SetValue(playerID, value, reason, transactionType)
		if not isValidNumber(value) then
			return false, "Invalid value"
		end

		-- Instead of dropping the transaction, wait until any active transaction completes.
		while transactionLocks[playerID] do
			task.wait(0.05)
		end
		transactionLocks[playerID] = true

		local success, result = safeProfileOperation(playerID, function(profile)
			local currentValue = profile.Data.currencies[self.saveKey] or self.defaultValue

			-- Clamp to valid range
			value = math.clamp(value, self.minValue, self.maxValue)

			-- Determine appropriate transaction type
			local changeAmount = value - currentValue
			local defaultType = nil -- Let logTransaction choose the appropriate fallback

			-- Save the transaction
			local transactionInfo = {
				transactionId = generateTransactionID(),
				timestamp = DateTime.now().UnixTimestampMillis * 1000,
				playerID = playerID,
				currencyKey = self.saveKey,
				previousValue = currentValue,
				newValue = value,
				changeAmount = changeAmount,
				reason = reason or "SetValue",
				transactionType = transactionType or defaultType
			}

			-- Update the value
			profile.Data.currencies[self.saveKey] = value

			-- Log the transaction
			logTransaction(transactionInfo)

			return true
		end)

		transactionLocks[playerID] = nil

		return success, not success and result or nil
	end

	-- Update IncrementValue to use valid transaction types
	function currencyData:IncrementValue(playerID, amount, reason, transactionType)
		if not isValidNumber(amount) then
			return false, "Invalid amount"
		end

		while transactionLocks[playerID] do
			task.wait(0.05)
		end
		transactionLocks[playerID] = true

		local success, result = safeProfileOperation(playerID, function(profile)
			local currentValue = profile.Data.currencies[self.saveKey] or self.defaultValue
			if not isValidNumber(currentValue) then
				currentValue = self.defaultValue
			end

			local newValue = currentValue + amount

			-- Clamp to valid range
			newValue = math.clamp(newValue, self.minValue, self.maxValue)

			-- Default transaction type based on whether adding or removing
			local defaultType = nil -- Let logTransaction choose appropriate fallback

			-- Save the transaction
			local transactionInfo = {
				transactionId = generateTransactionID(),
				timestamp = DateTime.now().UnixTimestampMillis * 1000,
				playerID = playerID,
				currencyKey = self.saveKey,
				previousValue = currentValue,
				newValue = newValue,
				changeAmount = amount,
				reason = reason or "IncrementValue",
				transactionType = transactionType or defaultType
			}

			-- Update the value
			profile.Data.currencies[self.saveKey] = newValue

			-- Log the transaction
			logTransaction(transactionInfo)

			return true
		end)

		transactionLocks[playerID] = nil

		return success, not success and result or nil
	end

	-- Update DecrementValue to use valid transaction types
	function currencyData:DecrementValue(playerID, amount, reason, transactionType)
		if not isValidNumber(amount) or amount < 0 then
			return false, "Invalid amount"
		end

		return self:IncrementValue(
			playerID, 
			-amount, 
			reason or "DecrementValue", 
			transactionType or Enum.AnalyticsEconomyTransactionType.Sink
		)
	end

	-- Update TransferValue to use valid transaction types
	function currencyData:TransferValue(fromPlayerID, toPlayerID, amount, reason, transactionType)
		if not isValidNumber(amount) or amount <= 0 then
			return false, "Invalid amount"
		end

		if fromPlayerID == toPlayerID then
			return false, "Cannot transfer to same player"
		end

		-- First check if sender has enough
		local currentValue, success = self:GetValue(fromPlayerID)
		if not success then
			return false, "Failed to get sender's currency"
		end

		if currentValue < amount then
			return false, "Insufficient funds"
		end

		-- Default transaction type for transfers if not specified
		local transferType = transactionType or Enum.AnalyticsEconomyTransactionType.Trade

		-- Wait until both players are free from other transactions.
		while transactionLocks[fromPlayerID] or transactionLocks[toPlayerID] do
			task.wait(0.05)
		end
		transactionLocks[fromPlayerID] = true
		transactionLocks[toPlayerID] = true

		-- Decrement sender
		local success1, error1 = safeProfileOperation(fromPlayerID, function(profile)
			local currentValue = profile.Data.currencies[self.saveKey] or self.defaultValue
			local newValue = math.clamp(currentValue - amount, self.minValue, self.maxValue)
			local transactionInfo = {
				transactionId = generateTransactionID(),
				timestamp = DateTime.now().UnixTimestampMillis * 1000,
				playerID = fromPlayerID,
				currencyKey = self.saveKey,
				previousValue = currentValue,
				newValue = newValue,
				changeAmount = -amount,
				reason = reason or "TransferSent",
				transactionType = transferType
			}
			profile.Data.currencies[self.saveKey] = newValue
			logTransaction(transactionInfo)
			return true
		end)
		if not success1 then
			transactionLocks[fromPlayerID] = nil
			transactionLocks[toPlayerID] = nil
			return false, "Failed to decrement sender: " .. (error1 or "Unknown error")
		end

		-- Increment receiver
		local success2, error2 = safeProfileOperation(toPlayerID, function(profile)
			local currentValue = profile.Data.currencies[self.saveKey] or self.defaultValue
			local newValue = math.clamp(currentValue + amount, self.minValue, self.maxValue)
			local transactionInfo = {
				transactionId = generateTransactionID(),
				timestamp = DateTime.now().UnixTimestampMillis * 1000,
				playerID = toPlayerID,
				currencyKey = self.saveKey,
				previousValue = currentValue,
				newValue = newValue,
				changeAmount = amount,
				reason = reason or "TransferReceived",
				transactionType = transferType
			}
			profile.Data.currencies[self.saveKey] = newValue
			logTransaction(transactionInfo)
			return true
		end)

		transactionLocks[fromPlayerID] = nil
		transactionLocks[toPlayerID] = nil

		if not success2 then
			-- Rollback sender's transaction
			safeProfileOperation(fromPlayerID, function(profile)
				local currentValue = profile.Data.currencies[self.saveKey] or self.defaultValue
				local rollbackValue = math.clamp(currentValue + amount, self.minValue, self.maxValue)
				profile.Data.currencies[self.saveKey] = rollbackValue
				logTransaction({
					transactionId = generateTransactionID(),
					timestamp = DateTime.now().UnixTimestampMillis * 1000,
					playerID = fromPlayerID,
					currencyKey = self.saveKey,
					previousValue = currentValue,
					newValue = rollbackValue,
					changeAmount = amount,
					reason = "TransferRollback",
					transactionType = Enum.AnalyticsEconomyTransactionType.Source  -- Use Source for rollbacks
				})
				return true
			end)
			return false, "Failed to increment receiver: " .. (error2 or "Unknown error")
		end

		return true
	end
end

-- Initialize each currency
for currencyName, currencyData in pairs(Currencies) do
	InitializeCurrency(currencyName, currencyData)
end

-- Purchase and Receipt Processing ( for public API methods)

-- Enhanced purchase function with better Studio handling
function Economy.PurchaseCurrencyAsync(player, currencyName, currencyAmount)
	if not player or not player:IsA("Player") then
		return false, "Invalid player"
	end

	local currency = Currencies[currencyName]
	if not currency then 
		return false, "Invalid currency: " .. tostring(currencyName)
	end

	if not currency.canBePurchased then
		return false, "Currency cannot be purchased: " .. tostring(currencyName)
	end

	-- Validate currency amount
	if not isValidNumber(currencyAmount) or currencyAmount <= 0 then
		return false, "Invalid amount"
	end

	-- Ensure that the currency has a purchaseIDs table and the amount is valid
	if not currency.purchaseIDs or not currency.purchaseIDs[currencyAmount] then
		return false, "No valid Purchase ID found for currency: " .. currencyName .. ", amount: " .. currencyAmount
	end

	local purchaseID = currency.purchaseIDs[currencyAmount].ID

	-- Production environment - prompt real purchase
	local success, errorMessage = pcall(function()
		MarketplaceService:PromptProductPurchase(player, purchaseID)
	end)

	if not success then
		warn("[Economy] Error prompting product purchase: " .. errorMessage)
		return false, "Failed to prompt purchase"
	end

	return true
end

function Economy.GetPurchaseOptions(currencyName)
	local currency = Currencies[currencyName]
	if not currency or not currency.canBePurchased then 
		return {}
	end

	local options = {}
	for amount, productId in pairs(currency.purchaseIDs) do
		table.insert(options, {
			amount = amount,
			productId = productId.ID
		})
	end

	-- Sort by amount
	table.sort(options, function(a, b)
		return a.amount < b.amount
	end)

	return options
end

-- Public API functions
function Economy.GetCurrency(currencyName)
	return Currencies[currencyName]
end

function Economy.GetAllCurrencies()
	local result = {}
	for name, currency in pairs(Currencies) do
		result[name] = currency
	end
	return result
end

function Economy.GetPlayerCurrencies(playerID)
	local result = {}
	for name, currency in pairs(Currencies) do
		result[name] = currency:GetValue(playerID)
	end
	return result
end

function Economy.ProcessReceipt(receiptInfo)

	-- Enhanced Studio testing mode
	if RunService:IsStudio() then
		print("[Economy] Auto-granting purchase in Studio environment for Product ID:", receiptInfo.ProductId)

		local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if player then
			
			local mapping = developerProductMapping[receiptInfo.ProductId]
			if mapping then
				local currency = mapping.currencyData
				local success, errorMsg = currency:IncrementValue(
					receiptInfo.PlayerId,
					mapping.amount,
					mapping.currencyData.purchaseIDs[mapping.amount].SKU,
					Enum.AnalyticsEconomyTransactionType.IAP -- Explicitly use IAP type for purchases
				)
				if not success then
					warn("[Economy] Failed to grant currency in Studio: " .. (errorMsg or "Unknown error"))
				end
			else
				warn("[Economy] Unknown developer product ID in Studio: " .. tostring(receiptInfo.ProductId))
			end
		end

		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- Production: If ReceiptId is nil during testing, generate a fallback ReceiptId
	if not receiptInfo.PurchaseId then
		warn("[Economy] ReceiptId is nil. Generating fallback ReceiptId")
		receiptInfo.PurchaseId = HttpService:GenerateGUID(false)
	end

	if receiptProcessingMap[receiptInfo.PurchaseId] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	receiptProcessingMap[receiptInfo.PurchaseId] = true

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		receiptProcessingMap[receiptInfo.PurchaseId] = nil
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local profile, errorMsg = safeGetProfile(receiptInfo.PlayerId)
	if not profile then
		receiptProcessingMap[receiptInfo.PurchaseId] = nil
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if profile.Data.processedReceipts[receiptInfo.PurchaseId] then
		receiptProcessingMap[receiptInfo.PurchaseId] = nil
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local mapping = developerProductMapping[receiptInfo.ProductId]
	if not mapping then
		warn("[Economy] Unknown developer product ID: " .. tostring(receiptInfo.ProductId))
		receiptProcessingMap[receiptInfo.PurchaseId] = nil
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local currency = mapping.currencyData
	local success, errorMsg = currency:IncrementValue(
		receiptInfo.PlayerId, 
		mapping.amount, 
		mapping.currencyData.purchaseIDs[mapping.amount].SKU,
		Enum.AnalyticsEconomyTransactionType.IAP -- Explicitly use IAP type for purchases
	)

	if not success then
		warn("[Economy] Failed to grant currency for receipt " .. receiptInfo.PurchaseId .. ": " .. (errorMsg or "Unknown error"))
		receiptProcessingMap[receiptInfo.PurchaseId] = nil
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Log the developer product name for production purchases
	print("[Economy] Purchase processed for product:", mapping.currencyData.purchaseIDs[mapping.amount].SKU)

	profile.Data.processedReceipts[receiptInfo.PurchaseId] = DateTime.now().UnixTimestampMillis * 1000

	local saveSuccess, saveError = pcall(function()
		profile:Save()
	end)

	if not saveSuccess then
		warn("[Economy] Failed to save profile after purchase: " .. (saveError or "Unknown error"))
	end

	receiptProcessingMap[receiptInfo.PurchaseId] = nil
	return Enum.ProductPurchaseDecision.PurchaseGranted
end


Players.PlayerAdded:Connect(PlayerAdded)
Players.PlayerRemoving:Connect(PlayerRemoving)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(PlayerAdded, player)
end


task.spawn(scheduleAutoSave)


MarketplaceService.ProcessReceipt = Economy.ProcessReceipt

return Economy
