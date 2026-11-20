function PLUGIN:MiseEnv(ctx)
    return { env = { { key = "SMOKE_OK", value = "yes" } }, cacheable = false }
end
