local Board = {}

-- Shared logical coordinates for simulation and its GUI projection. The dense
-- layouts scale both radii so every outgoing arc can clear its source peg.
function Board.New(basketCount)
    assert(type(basketCount) == "number" and basketCount == math.floor(basketCount)
        and basketCount >= 2 and basketCount <= 16,
        "Board.New requires an integer basket count from 2 to 16")

    local rows = basketCount - 1
    local spacing = 600 / basketCount
    local rowSpacing = 425 / math.max(1, rows - 1)
    local board = {
        Width = 720,
        Height = 1080,
        Rows = rows,
        Spacing = spacing,
        RowSpacing = rowSpacing,
        BallRadius = math.min(8, spacing * 0.15),
        PegRadius = math.min(5, spacing * 0.09),
        Gravity = 1500,
        Spawn = { X = 360, Y = 860 },
        Pegs = {},
        Baskets = {},
    }

    for row = 1, rows do
        for column = 1, row do
            board.Pegs[#board.Pegs + 1] = {
                X = 360 + (column - (row + 1) / 2) * spacing,
                -- With two baskets the single peg stays at the top, allowing
                -- the same initial drop and branching rules as larger boards.
                Y = 790 - (row - 1) * rowSpacing,
                Row = row,
                Column = column,
            }
        end
    end
    for index = 1, basketCount do
        board.Baskets[index] = {
            X = 60 + spacing * (index - 0.5),
            Y = 292,
            Width = spacing - 4,
        }
    end
    return board
end

return Board
