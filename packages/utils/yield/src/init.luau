--!strict
--!native

const function Yield(fns: { () -> () })
    local count = #fns
    if count == 0 then return end

    local parent = coroutine.running()
    local pending = count
    local resumed = false

    for idx = 1, count do
        local fn = fns[idx]
        task.spawn(function()
            local ok, err = pcall(fn)
            if not ok then
                warn(`[yield] error: {err}`)
            end

            pending -= 1
            if pending == 0 and not resumed then
                resumed = true
                task.spawn(parent)
            end
        end)
    end

    coroutine.yield()
end

return Yield
