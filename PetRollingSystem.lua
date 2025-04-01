local EggRollingSystem = {}

local HttpService = game:GetService("HttpService")

-- Type definitions
export type Stats = {
	strength: number,
	speed: number,
}

export type PetDefinition = {
	rarity: string,
	model: string,
	stats: Stats,
}

export type Pet = PetDefinition & {
	name: string,
	petId: string,
}

export type EggType = {
	price: number,
	model: string,
	description: string,
	petWeights: { [string]: number },
}

export type EggSummary = {
	id: string,
	price: number,
	model: string,
	description: string,
}

export type EggContent = {
	rarity: string,
	probability: number,
}

-- Function to clone a table
local function deepClone(original: any): any
	if type(original) ~= "table" then
		return original
	end
	local copy = {}
	for key, value in pairs(original) do
		copy[key] = deepClone(value)
	end
	return copy
end

-- Pet definitions table
local PetDefinitions: { [string]: PetDefinition } = {
	Kitty = { rarity = "Common", model = "KittyModel", stats = { strength = 1, speed = 2 } },
	Puppy = { rarity = "Common", model = "PuppyModel", stats = { strength = 2, speed = 1 } },
	Bunny = { rarity = "Common", model = "BunnyModel", stats = { strength = 1, speed = 1 } },
	Fox = { rarity = "Uncommon", model = "FoxModel", stats = { strength = 3, speed = 2 } },
	Raccoon = { rarity = "Uncommon", model = "RaccoonModel", stats = { strength = 2, speed = 3 } },
	Lion = { rarity = "Rare", model = "LionModel", stats = { strength = 4, speed = 3 } },
	Tiger = { rarity = "Rare", model = "TigerModel", stats = { strength = 3, speed = 4 } },
	Dragon = { rarity = "Epic", model = "DragonModel", stats = { strength = 5, speed = 4 } },
	Phoenix = { rarity = "Epic", model = "PhoenixModel", stats = { strength = 4, speed = 5 } },
	Unicorn = { rarity = "Legendary", model = "UnicornModel", stats = { strength = 6, speed = 6 } },
	Griffin = { rarity = "Legendary", model = "GriffinModel", stats = { strength = 7, speed = 5 } },
	SuperRarePet = { rarity = "Mythic", model = "SuperRarePetModel", stats = { strength = 14, speed = 8 } },
	UberRarePet = { rarity = "Secret", model = "UberRarePetModel", stats = { strength = 34, speed = 23 } },
}

-- Egg types table
local EggTypes: { [string]: EggType } = {
	Basic = {
		price = 100,
		model = "BasicEgg",
		description = "A basic egg with common pets",
		petWeights = {
			Kitty = 50,
			Puppy = 40,
			Bunny = 35,
		},
	},
	Deluxe = {
		price = 250,
		model = "DeluxeEgg",
		description = "A deluxe egg with a chance for uncommon pets",
		petWeights = {
			Kitty = 30,
			Puppy = 25,
			Fox = 15,
			Raccoon = 10,
		},
	},
	Premium = {
		price = 500,
		model = "PremiumEgg",
		description = "A premium egg with a chance for rare pets",
		petWeights = {
			Fox = 25,
			Raccoon = 20,
			Lion = 10,
			Tiger = 8,
		},
	},
	Ultra = {
		price = 1000,
		model = "UltraEgg",
		description = "An ultra egg with a chance for epic pets",
		petWeights = {
			Lion = 20,
			Tiger = 15,
			Dragon = 8,
			Phoenix = 5,
		},
	},
	Mythic = {
		price = 2500,
		model = "MythicEgg",
		description = "A mythic egg with a chance for legendary pets",
		petWeights = {
			Dragon = 15,
			Phoenix = 10,
			Unicorn = 3,
			Griffin = 1,
			SuperRarePet = 0.05,
			UberRarePet = 0.00002905,
		},
	},
}

-- Linear luck boosts per rarity (replaced exponential scaling)
local LuckBoostsPerRarity = {
	Common = 0,
	Uncommon = 0.5,
	Rare = 1.0,
	Epic = 1.5,
	Legendary = 2.0,
	Mythic = 2.5,
	Secret = 3.0
}

-- Calculate luck multiplier for a specific pet rarity and luck amount
local function GetLuckMultiplier(rarity: string, luckAmount: number): number
	local boost = LuckBoostsPerRarity[rarity] or 0
	-- Linear scaling formula
	return 1 + (boost * luckAmount / 100)
end

-- Adjust pet weights based on luck (linear scaling)
local function AdjustWeights(petWeights: { [string]: number }, luckAmount: number?): { [string]: number }
	local adjustedWeights = {}
	local luckAmount = luckAmount or 0

	for petName, weight in pairs(petWeights) do
		local petDefinition: PetDefinition? = PetDefinitions[petName]
		if petDefinition then
			local luckMultiplier = GetLuckMultiplier(petDefinition.rarity, luckAmount)
			adjustedWeights[petName] = weight * luckMultiplier
		else
			-- If pet definition is missing, keep original weight as fallback
			adjustedWeights[petName] = weight
		end
	end

	return adjustedWeights
end

-- Calculate the total weight of all pets in an egg with adjustments for luck
local function GetTotalWeight(adjustedWeights: { [string]: number }): number
	local total: number = 0
	for _, weight in pairs(adjustedWeights) do
		total = total + weight
	end
	return total
end

-- Get egg information by ID
function EggRollingSystem:GetEggInfoById(eggId: string): EggType?
	local egg = EggTypes[eggId]
	if egg then
		return deepClone(egg)
	else
		return nil
	end
end

-- Roll for a pet from a specific egg
function EggRollingSystem:RollPetFromEgg(eggId: string, luckAmount: number?): Pet?
	local eggInfo: EggType? = EggTypes[eggId]
	if not eggInfo then
		return nil
	end

	local luckAmount = luckAmount or 0
	local adjustedWeights = AdjustWeights(eggInfo.petWeights, luckAmount)
	local totalWeight = GetTotalWeight(adjustedWeights)

	-- Random value between 0 and totalWeight
	local randomValue: number = math.random() * totalWeight
	local currentWeight: number = 0

	for petName, weight in pairs(adjustedWeights) do
		currentWeight = currentWeight + weight
		if randomValue <= currentWeight then
			local petDefinition: PetDefinition? = PetDefinitions[petName]
			if petDefinition then
				local newPet: Pet = deepClone(petDefinition)
				newPet.name = petName
				newPet.petId = HttpService:GenerateGUID()
				return newPet
			end
		end
	end

	-- Fallback in case something goes wrong with the probabilities
	local fallbackPets = {}
	for petName in pairs(eggInfo.petWeights) do
		table.insert(fallbackPets, petName)
	end

	if #fallbackPets > 0 then
		local randomPetName = fallbackPets[math.random(1, #fallbackPets)]
		local petDefinition = PetDefinitions[randomPetName]
		if petDefinition then
			local newPet: Pet = deepClone(petDefinition)
			newPet.name = randomPetName
			newPet.petId = HttpService:GenerateGUID()
			return newPet
		end
	end

	return nil
end

-- Roll multiple pets from a specific egg at once
function EggRollingSystem:RollMultiplePetsFromEgg(eggId: string, count: number, luckAmount: number?): { [number]: Pet }
	local results: { [number]: Pet } = {}
	for i = 1, count do
		local pet: Pet? = self:RollPetFromEgg(eggId, luckAmount)
		if pet then
			table.insert(results, pet)
		end
	end
	return results
end

-- Get all available egg types
function EggRollingSystem:GetAllEggTypes(): { [number]: EggSummary }
	local eggsList: { [number]: EggSummary } = {}
	for eggId, eggInfo in pairs(EggTypes) do
		table.insert(eggsList, {
			id = eggId,
			price = eggInfo.price,
			model = eggInfo.model,
			description = eggInfo.description,
		})
	end
	return eggsList
end

-- Get all possible pets in an egg with their probabilities
function EggRollingSystem:GetEggContents(eggId: string, luckAmount: number?): { [string]: EggContent }?
	local eggInfo: EggType? = EggTypes[eggId]
	if not eggInfo then
		return nil
	end

	local luckAmount = luckAmount or 0
	local adjustedWeights = AdjustWeights(eggInfo.petWeights, luckAmount)
	local totalWeight = GetTotalWeight(adjustedWeights)
	local contents: { [string]: EggContent } = {}

	for petName, weight in pairs(adjustedWeights) do
		local petDefinition: PetDefinition? = PetDefinitions[petName]
		if petDefinition then
			contents[petName] = {
				rarity = petDefinition.rarity,
				probability = (weight / totalWeight) * 100,
			}
		end
	end

	return contents
end

-- Added function to help developers test and visualize luck effects
function EggRollingSystem:SimulateLuckEffect(eggId: string, luckValues: {number}): {[number]: {[string]: number}}
	local eggInfo: EggType? = EggTypes[eggId]
	if not eggInfo then
		return {}
	end

	local results = {}
	for _, luckAmount in ipairs(luckValues) do
		local adjustedWeights = AdjustWeights(eggInfo.petWeights, luckAmount)
		local totalWeight = GetTotalWeight(adjustedWeights)
		local probabilities = {}

		for petName, weight in pairs(adjustedWeights) do
			probabilities[petName] = (weight / totalWeight) * 100
		end

		results[luckAmount] = probabilities
	end

	return results
end

return EggRollingSystem
