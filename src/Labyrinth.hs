module Labyrinth(
  Labyrinth(..), 
  BoxState(..), 
  RedrawInfo(..),
  labyConstruct, 
  labyMarkBox,
  labyGetRedrawInfo,
  labyStateToColor) where

import Control.Concurrent.STM(STM)
import Control.Concurrent.STM.TArray(TArray)
import Data.Array.MArray(newArray,writeArray,readArray)
import Rectangle
import Grid

data BoxState = Empty | Border | Start | End deriving(Eq, Show)

type LabyArray = TArray (Int, Int) BoxState

data Labyrinth = Labyrinth {
  labyBoxState :: LabyArray,
  labyGrid :: Grid Int
}

data RedrawInfo = RedrawInfo {
  labyRedrIntersect :: Rectangle Int,
  labyRedrGrid :: Grid Int,
  labyRedrBoxes :: [ (BoxState, RectangleInScreenCoordinates Int) ]
} deriving(Show)

marginFactor :: Int
marginFactor = 32

labyConstruct :: Int -> Int -> (Int, Int) -> STM Labyrinth
labyConstruct boxSize borderSize (totalWidth, totalHeight) = do
  let leftMargin     = quot totalWidth marginFactor
      topMargin      = quot totalHeight marginFactor
      xBoxCnt        = quot (totalWidth - 2 * leftMargin) boxSize
      yBoxCnt        = quot (totalHeight - 2 * topMargin) boxSize
      width          = xBoxCnt * boxSize + borderSize
      height         = yBoxCnt * boxSize + borderSize
      arrayDimension = ((0, 0), (xBoxCnt - 1, yBoxCnt - 1))
  array <- newArray arrayDimension Empty
  return Labyrinth
    { labyBoxState = array
    , labyGrid     = Grid
      { grScreenSize = (totalWidth, totalHeight)
      , grRectangle  = Rectangle (quot (totalWidth - width) 2)
                                 (quot (totalHeight - height) 2)
                                 width
                                 height
      , grBoxSize    = boxSize
      , grXBoxCnt    = xBoxCnt
      , grYBoxCnt    = yBoxCnt
      , grBorderSize = borderSize
      }
    }

labyMarkBox :: PointInScreenCoordinates Int -> BoxState -> Maybe Labyrinth -> STM (Maybe (Labyrinth, Rectangle Int))
labyMarkBox _     _        Nothing          = return Nothing
labyMarkBox point boxState (Just labyrinth) = 
  do
    let grid = labyGrid labyrinth
        box  = grPixelToBox grid point
    case box of
      Just pt -> let repaintArea = grBoxToPixel grid pt
                 in case repaintArea of
                    Just area -> do writeArray (labyBoxState labyrinth) pt boxState
                                    return $ Just (labyrinth, area)
                    Nothing -> return Nothing
      Nothing -> return Nothing

labyGetRedrawInfo :: Maybe Labyrinth -> Rectangle Int -> STM (Maybe RedrawInfo)
labyGetRedrawInfo Nothing _ = return Nothing
labyGetRedrawInfo (Just labyrinth) area =
  let rectangle = grRectangle $ labyGrid labyrinth
  in case rIntersect area rectangle of 
    Just intersection -> do boxes <- labyGetBoxesInsideArea intersection labyrinth
                            return $ Just RedrawInfo { 
                              labyRedrIntersect = intersection,
                              labyRedrGrid = labyGrid labyrinth,
                              labyRedrBoxes = boxes
                            }
    Nothing -> return Nothing

labyGetBoxesInsideArea :: RectangleInScreenCoordinates Int -> Labyrinth 
                                                           -> STM [ (BoxState, RectangleInScreenCoordinates Int)]                                                        
labyGetBoxesInsideArea area labyrinth =
  do
    let  grid = labyGrid labyrinth
         boxArea = grPixelAreaToBoxArea grid area
         array = labyBoxState labyrinth
    case boxArea of 
      Just boxes -> sequence [ boxDatum | 
                      x <- [(rTopLeftX boxes)..(rBottomRightX boxes)],
                      y <- [(rTopLeftY boxes)..(rBottomRightY boxes)],
                      Just boxDatum <- [labyGetBoxData array grid (x,y)] ] 
      Nothing -> return []

labyGetBoxData :: LabyArray -> Grid Int 
                            -> PointInGridCoordinates Int 
                            -> Maybe (STM (BoxState, RectangleInScreenCoordinates Int))
labyGetBoxData array grid point =
  let pixel = grBoxToPixel grid point
  in case pixel of 
    Just p -> Just $ labyGetBoxTuple array point p
    Nothing -> Nothing

labyGetBoxTuple :: LabyArray -> PointInGridCoordinates Int 
                             -> Rectangle Int 
                             -> STM (BoxState, RectangleInScreenCoordinates Int)
labyGetBoxTuple array point rectangle =
  do
    boxState <- readArray array point
    return (boxState, rectangle)

labyStateToColor :: BoxState -> (Double, Double, Double)
labyStateToColor Empty = (255, 255, 255)
labyStateToColor Border = (0, 0, 255)
labyStateToColor _ = (255, 0, 0)


