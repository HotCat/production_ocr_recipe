module BankRecipes (bankRecipes, bankRecipe) where

bankRecipes :: [(String, Int)]
bankRecipes = [("平安银行", 16), ("郑州银行", 12)]

bankRecipe :: Int -> (String, Int)
bankRecipe index
  | index >= 0 && index < length bankRecipes = bankRecipes !! index
  | otherwise = ("未知银行 #" ++ show index, 16)
