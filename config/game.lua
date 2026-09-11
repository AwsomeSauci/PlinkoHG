-- Game design data. Weights are relative, do not have to add up to 100,
-- and are independent of basket position and animation.
-- Keep basket IDs stable when changing their order, colour or payout.
return {
    Version = 2,
    InitialBalls = 12,
    RefillCap = 20,
    RefillSeconds = 30,
    BatchSize = 5,
    GrantSize = 10,
    MaxInventory = 1000000,
    Locale = "ru",
    Baskets = {
        { Id = "ruby_left", Weight = 1, Rewards = {{Type = "points", Amount = 100}}, Color = "D89973" },
        { Id = "amber_left", Weight = 3, Rewards = {{Type = "points", Amount = 50}}, Color = "DEAC66" },
        { Id = "gold_left", Weight = 6, Rewards = {{Type = "points", Amount = 25}}, Color = "DDC781" },
        { Id = "mint_left", Weight = 15, Rewards = {{Type = "points", Amount = 10}}, Color = "B9C47F" },
        { Id = "aqua_left", Weight = 25, Rewards = {{Type = "points", Amount = 5}}, Color = "8CA377" },
        { Id = "aqua_right", Weight = 25, Rewards = {{Type = "points", Amount = 5}}, Color = "8CA377" },
        { Id = "mint_right", Weight = 15, Rewards = {{Type = "points", Amount = 10}}, Color = "B9C47F" },
        { Id = "gold_right", Weight = 6, Rewards = {{Type = "points", Amount = 25}}, Color = "DDC781" },
        { Id = "amber_right", Weight = 3, Rewards = {{Type = "points", Amount = 50}}, Color = "DEAC66" },
        { Id = "ruby_right", Weight = 1, Rewards = {{Type = "points", Amount = 100}}, Color = "D89973" },
    },
}
