local M = {}
function M.join(a, b)
    if a:sub(-1) == "/" then return a .. b end
    return a .. "/" .. b
end
return M
