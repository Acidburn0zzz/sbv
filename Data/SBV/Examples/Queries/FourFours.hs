-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.Examples.Queries.FourFours
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- A query based solution to the four-fours puzzle.
-- Inspired by <http://www.gigamonkeys.com/trees/>
--
-- @
-- Try to make every number between 0 and 20 using only four 4s and any
-- mathematical operation, with all four 4s being used each time.
-- @
--
-- We pretty much follow the structure of <http://www.gigamonkeys.com/trees/>,
-- with the exception that we generate the trees filled with symbolic operators
-- and ask the SMT solver to find the appropriate fillings.
-----------------------------------------------------------------------------

{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Data.SBV.Examples.Queries.FourFours where

import Data.SBV
import Data.SBV.Control

import Data.List (inits, tails)
import Data.Maybe

-- | Supported binary operators. To keep the search-space small, we will only allow division by @2@ or @4@,
-- and exponentiation will only be to the power @0@. This does restrict the search space, but is sufficient to
-- solve all the instances.
data BinOp = Plus | Minus | Times | Divide | Expt
mkSymbolicEnumeration ''BinOp

-- | Supported unary operators. Similar to 'BinOp' case, we will restrict square-root and factorial to
-- be only applied to the value @4.
data UnOp  = Negate | Sqrt | Factorial
mkSymbolicEnumeration ''UnOp

-- | Symbolic variant of 'BinOp'.
type SBinOp = SBV BinOp

-- | Symbolic variant of 'UnOp'.
type SUnOp  = SBV UnOp

-- | The shape of a tree, either a binary node, or a unary node, or the number @4@, represented hear by
-- the constructor @F@. We parameterize by the operator type: When doing symbolic computations, we'll fill
-- those with 'SBinOp' and 'SUnOp'. When finding the shapes, we will simply put unit values, i.e., holes.
data T b u = B b (T b u) (T b u)
           | U u (T b u)
           | F

-- | A rudimentary 'Show' instance for trees, nothing fancy.
instance Show (T BinOp UnOp) where
   show F       = "4"
   show (U u t) = case u of
                    Negate    -> "-" ++ show t
                    Sqrt      -> "sqrt(" ++ show t ++ ")"
                    Factorial -> show t ++ "!"
   show (B o l r) = "(" ++ show l ++ " " ++ so ++ " " ++ show r ++ ")"
     where so = fromMaybe (error $ "Unexpected operator: " ++ show o)
                        $ o `lookup` [(Plus, "+"), (Minus, "-"), (Times, "*"), (Divide, "/"), (Expt, "^")]

-- | Construct all possible tree shapes. The argument here follows the logic in <http://www.gigamonkeys.com/trees/>:
-- We simply construct all possible shapes and extend with the operators. The number of such trees is:
--
-- >>> length allPossibleTrees
-- 640
--
-- Note that this is a /lot/ smaller than what is generated by <http://www.gigamonkeys.com/trees/>. (There, the
-- number of trees is 10240000: 16000 times more than what we have to consider!)
allPossibleTrees :: [T () ()]
allPossibleTrees = trees $ replicate 4 F
  where trees :: [T () ()] -> [T () ()]
        trees [x] = [x, U () x]
        trees xs  = do (left, right) <- splits
                       t1            <- trees left
                       t2            <- trees right
                       trees [B () t1 t2]
          where splits = init $ tail $ zip (inits xs) (tails xs)

-- | Given a tree with hols, fill it with symbolic operators. This is the /trick/ that allows
-- us to consider only 640 trees as opposed to over 10 million.
fill :: T () () -> Symbolic (T SBinOp SUnOp)
fill (B _ l r) = B <$> free_ <*> fill l <*> fill r
fill (U _ t)   = U <$> free_ <*> fill t
fill F         = return F

-- | Minor helper for writing "symbolic" case statements. Simply walks down a list
-- of values to match against a symbolic version of the key.
sCase :: (SymWord a, Mergeable v) => SBV a -> [(a, v)] -> v
sCase k = walk
  where walk []              = error "sCase: Expected a non-empty list of cases!"
        walk [(_, v)]        = v
        walk ((k1, v1):rest) = ite (k .== literal k1) v1 (walk rest)

-- | Evaluate a symbolic tree, obtaining a symbolic value. Note how we structure
-- this evaluation so we impose extra constraints on what values square-root, divide
-- etc. can take. This is the power of the symbolic approach: We can put arbitrary
-- symbolic constraints as we evaluate the tree.
eval :: T SBinOp SUnOp -> Symbolic SInteger
eval tree = case tree of
              B b l r -> eval l >>= \l' -> eval r >>= \r' -> binOp b l' r'
              U u t   -> eval t >>= uOp u
              F       -> return 4

  where binOp :: SBinOp -> SInteger -> SInteger -> Symbolic SInteger
        binOp o l r = do constrain $ o .== literal Divide ==> r .== 4 ||| r .== 2
                         constrain $ o .== literal Expt   ==> r .== 0
                         return $ sCase o
                                    [ (Plus,    l+r)
                                    , (Minus,   l-r)
                                    , (Times,   l*r)
                                    , (Divide,  l `sDiv` r)
                                    , (Expt,    1)   -- exponent is restricted to 0, so the value is 1
                                    ]

        uOp :: SUnOp -> SInteger -> Symbolic SInteger
        uOp o v = do constrain $ o .== literal Sqrt      ==> v .== 4
                     constrain $ o .== literal Factorial ==> v .== 4
                     return $ sCase o
                                [ (Negate,    -v)
                                , (Sqrt,       2)  -- argument is restricted to 4, so the value is 2
                                , (Factorial, 24)  -- argument is restricted to 4, so the value is 24
                                ]

-- | In the query mode, find a filling of a given tree shape /t/, such that it evalutes to the
-- requested number /i/. Note that we return back a concrete tree.
generate :: Integer -> T () () -> IO (Maybe (T BinOp UnOp))
generate i t = runSMT $ do symT <- fill t
                           val  <- eval symT
                           constrain $ val .== literal i
                           query $ do cs <- checkSat
                                      case cs of
                                        Sat -> Just <$> construct symT
                                        _   -> return Nothing
    where -- Walk through the tree, ask the solver for
          -- the assignment to symbolic operators and fill back.
          construct F           = return F
          construct (U o s')    = do uo <- getValue o
                                     U uo <$> construct s'
          construct (B b l' r') = do bo <- getValue b
                                     B bo <$> construct l' <*> construct r'

-- | Given an integer, walk through all possible tree shapes (at most 640 of them), and find a
-- filling that solves the puzzle.
find :: Integer -> IO ()
find i = go allPossibleTrees
  where go []     = putStrLn $ show i ++ ": No solution found."
        go (t:ts) = do chk <- generate i t
                       case chk of
                         Nothing -> go ts
                         Just r  -> putStrLn $ show i ++ ": " ++ show r

-- | Solution to the puzzle. We have:
--
-- >>> puzzle
-- 0: (4 + (4 - (4 + 4)))
-- 1: (4 / (4 + (4 - 4)))
-- 2: sqrt((4 + (4 * (4 - 4))))
-- 3: (4 - (4 ^ (4 - 4)))
-- 4: (4 * (4 ^ (4 - 4)))
-- 5: (4 + (4 ^ (4 - 4)))
-- 6: (4 + sqrt((4 * (4 / 4))))
-- 7: (4 + (4 - (4 / 4)))
-- 8: (4 - (4 - (4 + 4)))
-- 9: (4 + (4 + (4 / 4)))
-- 10: (4 + (4 + (4 - sqrt(4))))
-- 11: (4 + ((4 + 4!) / 4))
-- 12: (4 * (4 - (4 / 4)))
-- 13: (4! + ((sqrt(4) - 4!) / sqrt(4)))
-- 14: (4 + (4 + (4 + sqrt(4))))
-- 15: (4 + ((4! - sqrt(4)) / sqrt(4)))
-- 16: (4 + (4 + (4 + 4)))
-- 17: (4 + ((sqrt(4) + 4!) / sqrt(4)))
-- 18: -(4 + (4 - (4! + sqrt(4))))
-- 19: -(4 - (4! - (4 / 4)))
-- 20: (4 * (4 + (4 / 4)))
puzzle :: IO ()
puzzle = mapM_ find [0 .. 20]
