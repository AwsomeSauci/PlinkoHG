local Board = require "scripts.simulation.board"
local Flight = require "scripts.simulation.flight"
local FlightSimulator = {}

function FlightSimulator.New()
    local board
    return {
        Configure = function(self, count) board = Board.New(count) end,
        Create = function(self, descriptor) return Flight.New(assert(board), descriptor) end,
        Update = function(self, flight, dt) return Flight.Update(flight, dt) end,
    }
end

return FlightSimulator
