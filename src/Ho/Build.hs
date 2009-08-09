module Ho.Build (
    module Ho.Type,
    dumpHoFile,
    parseFiles,
    buildLibrary
    ) where


import Control.Concurrent
import Control.Monad.Identity
import Data.Binary
import Data.Char
import Data.IORef
import Data.List hiding(union)
import Data.Monoid
import Data.Tree
import Data.Version(Version,parseVersion,showVersion)
import Debug.Trace
import Maybe
import Monad
import Prelude hiding(print,putStrLn)
import System.IO hiding(print,putStrLn)
import System.Mem
import System.Posix.Files
import Text.Printf
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.UTF8 as LBS
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Text.PrettyPrint.HughesPJ as PPrint

import CharIO
import DataConstructors
import Doc.DocLike
import Doc.PPrint
import Doc.Pretty
import E.E
import E.Rules
import E.Show
import E.Traverse(emapE)
import E.TypeCheck()
import FrontEnd.Class
import FrontEnd.FrontEnd
import FrontEnd.HsParser
import FrontEnd.HsSyn
import FrontEnd.Infix
import FrontEnd.ParseMonad
import FrontEnd.SrcLoc
import FrontEnd.Syn.Options
import FrontEnd.Unlit
import FrontEnd.Warning
import Ho.Binary
import Ho.Collected()
import Ho.Library
import Ho.Type
import Options
import PackedString(PackedString,packString,unpackPS)
import RawFiles(prelude_m4)
import Support.CFF
import Util.FilterInput
import Util.Gen hiding(putErrLn,putErr,putErrDie)
import Util.SetLike
import Version.Config(revision)
import Version.Version(versionString)
import qualified FlagDump as FD
import qualified FlagOpts as FO
import qualified Support.MD5 as MD5
import qualified Util.Graph as G


--
-- Ho File Format
--
-- ho files are standard CFF format files (PNG-like) as described in the Support.CFF modules.
--
-- the CFF magic for the files is the string "JHC"
--
-- JHDR - header info, contains a list of modules contained and dependencies that need to be checked to read the file
-- LIBR - only present if this is a library, contains library metainfo
-- IDEP - immutable import information, needed to tell if ho files are up to date
-- LINK - redirect to another file for systems without symlinks
-- DEFS - definitions type checking information
-- CORE - compiled core and associated data
-- LDEF - library map of module group name to DEFS
-- LCOR - library map of module group name to CORE
-- GRIN - compiled grin code


{-
 - We separate the data into various chunks for logical layout as well as the important property that
 - each chunk is individually compressed and accessable. What this means is
 - that we can skip chunks we don't need. for instance, during the final link
 - we have no need of the haskell type checking information, we are only
 - interested in the compiled code, so we can jump directly to it. If we relied on straight
 - serialization, we would have to parse all preceding information just to discard it right away.
 - We also lay them out so that we can generate error messages quickly. for instance, we can determine
 - if a symbol is undefined quickly, before it has to load the typechecking data.
 -
 -}

-- | this should be updated every time the on-disk file format changes for a chunk. It is independent of the
-- version number of the compiler.


type LibraryName = PackedString

findFirstFile :: String -> [(FilePath,a)] -> IO (LBS.ByteString,FilePath,a)
findFirstFile err [] = FrontEnd.Warning.err "missing-dep" ("Module not found: " ++ err) >> fail ("Module not found: " ++ err) -- return (error "findFirstFile not found","",undefined)
findFirstFile err ((x,a):xs) = flip catch (\e ->   findFirstFile err xs) $ do
    bs <- LBS.readFile x
    return (bs,x,a)


data ModDone
    = ModNotFound
    | ModLibrary ModuleGroup Library
    | Found SourceCode

data Done = Done {
    knownSourceMap  :: Map.Map SourceHash (Module,[Module]),
    validSources    :: Set.Set SourceHash,
    loadedLibraries :: Map.Map LibraryName Library,
    hosEncountered  :: Map.Map HoHash     (FilePath,HoHeader,HoIDeps,Ho),
    modEncountered  :: Map.Map Module     ModDone
    }
    {-! derive: Monoid, update !-}

fileOrModule f = case reverse f of
                   ('s':'h':'.':_)     -> Right f
                   ('s':'h':'l':'.':_) -> Right f
                   _                   -> Left $ Module f


replaceSuffix suffix fp = reverse (dropWhile ('.' /=) (reverse fp)) ++ suffix

hoFile :: FilePath -> Maybe Module -> SourceHash -> FilePath
hoFile fp mm sh = case optHoDir options of
    Nothing -> replaceSuffix "ho" fp
    Just hdir -> case mm of
        Nothing -> hdir ++ "/" ++ show sh ++ ".ho"
        Just m -> hdir ++ "/" ++ map ft (show m) ++ ".ho" where
            ft '/' = '.'
            ft x = x

findHoFile :: IORef Done -> FilePath -> Maybe Module -> SourceHash -> IO (Bool,FilePath)
findHoFile done_ref fp mm sh = do
    done <- readIORef done_ref
    let honame = hoFile fp mm sh
    writeIORef done_ref (done { validSources = Set.insert sh (validSources done) })
    if sh `Set.member` validSources done || optIgnoreHo options then return (False,honame) else do
    onErr (return (False,honame)) (readHoFile honame) $ \ (hoh,hidep,ho) -> do
        case hohHash hoh `Map.lookup` hosEncountered done of
            Just (fn,_,_,a) -> return (True,fn)
            Nothing -> do
                modifyIORef done_ref (knownSourceMap_u $ mappend (hoIDeps hidep))
                modifyIORef done_ref (validSources_u $ Set.union (Set.fromList . map snd $ hoDepends hidep))
                modifyIORef done_ref (hosEncountered_u $ Map.insert (hohHash hoh) (honame,hoh,hidep,ho))
                return (True,honame)



onErr :: IO a -> IO b -> (b -> IO a) -> IO a
onErr err good cont = catch (good >>= \c -> return (cont c)) (\_ -> return err) >>= id

fetchSource :: IORef Done -> [FilePath] -> Maybe Module -> IO Module
fetchSource _ [] _ = fail "No files to load"
fetchSource done_ref fs mm = do
    let mod = maybe (head fs) show mm
        killMod = case mm of
            Nothing -> fail $ "Could not load file: " ++ show fs
            Just m -> modifyIORef done_ref (modEncountered_u $ Map.insert m ModNotFound) >> return m
    onErr killMod (findFirstFile mod [ (f,undefined) | f <- fs]) $ \ (lbs,fn,_) -> do
    let hash = MD5.md5lazy lbs
    (foundho,mho) <- findHoFile done_ref fn mm hash
    done <- readIORef done_ref
    (mod,m,ds) <- case mlookup hash (knownSourceMap done) of
        Just (m,ds) -> do return (Left lbs,m,ds)
        Nothing -> do
            hmod <- parseHsSource fn lbs
            let m = hsModuleName hmod
                ds = hsModuleRequires hmod
            writeIORef done_ref (knownSourceMap_u (Map.insert hash (m,ds)) done)
            return (Right hmod,m,ds)
    case mm of
        Just m' | m /= m' -> do
            putErrLn $ "Skipping file" <+> fn <+> "because it's module declaration of" <+> show m <+> "does not equal the expected" <+> show m'
            killMod
        _ -> do
            let sc (Right mod) = SourceParsed hash ds mod fn mho
                sc (Left lbs) = SourceRaw hash ds m lbs fn mho
            modifyIORef done_ref (modEncountered_u $ Map.insert m (Found (sc mod)))
            fn' <- shortenPath fn
            mho' <- shortenPath mho
            case foundho of
                False -> putProgressLn $ printf "%-23s [%s]" (show m) fn'
                True -> putProgressLn $ printf "%-23s [%s] <%s>" (show m) fn' mho'
            mapM_ (resolveDeps done_ref) ds
            return m

resolveDeps :: IORef Done -> Module -> IO ()
resolveDeps done_ref m = do
    done <- readIORef done_ref
    if isJust $ m `mlookup` modEncountered done then return () else do
    fetchSource done_ref (map fst $ searchPaths (show m)) (Just m)
    return ()


type LibInfo = (Map.Map Module ModuleGroup, Map.Map ModuleGroup [ModuleGroup], Set.Set Module,Map.Map ModuleGroup HoBuild,Map.Map ModuleGroup HoTcInfo)

data CompNode = CompNode !HoHash [CompNode] !(IORef CompLink)
data CompLink
    = CompLinkUnit CompUnit
    | CompCollected CollectedHo CompUnit
    | CompTcCollected HoTcInfo CompUnit
    | CompLinkLib (ModuleGroup,LibInfo) CompUnit

compLinkCompUnit (CompLinkUnit cu) = cu
compLinkCompUnit (CompCollected _ cu) = cu
compLinkCompUnit (CompTcCollected _ cu) = cu
compLinkCompUnit (CompLinkLib _ cu) = cu

type CompUnitGraph = [(HoHash,([HoHash],CompUnit))]

data CompUnit
    = CompHo HoHeader HoIDeps Ho
    | CompSources [SourceCode]
    | CompTCed ((HoTcInfo,TiData,[(HoHash,HsModule)],[String]))
    | CompDummy
    | CompLibrary Ho Library


data SourceCode
    = SourceParsed { sourceHash :: SourceHash, sourceDeps :: [Module]
                   , sourceModule :: HsModule, sourceFP :: FilePath, sourceHoName :: FilePath }
    | SourceRaw    { sourceHash :: SourceHash, sourceDeps :: [Module]
                   , sourceModName :: Module, sourceLBS :: LBS.ByteString, sourceFP :: FilePath, sourceHoName :: FilePath }

sourceIdent SourceParsed { sourceModule = m } = show $ hsModuleName m
sourceIdent SourceRaw { sourceModName = fp } = show fp

class ProvidesModules a where
    providesModules :: a -> [Module]
    providesModules _ = []

instance ProvidesModules HoIDeps where
    providesModules hoh = fsts $ hoDepends hoh

instance ProvidesModules HoLib where
    providesModules hl = Map.keys (hoModuleMap hl)

instance ProvidesModules CompUnit where
    providesModules (CompHo _ hoh _)   = providesModules hoh
    providesModules (CompSources ss) = concatMap providesModules ss
    providesModules (CompLibrary ho libr) = libProvides (hoModuleGroup ho) libr
    providesModules CompDummy = []

instance ProvidesModules CompLink where
--    providesModules CompLinkNone = []
    providesModules (CompLinkUnit cu) = providesModules cu
    providesModules (CompCollected _ cu) = providesModules cu
    providesModules (CompTcCollected _ cu) = providesModules cu

instance ProvidesModules SourceCode where
    providesModules SourceParsed { sourceModule = mod } = [hsModuleName mod]
    providesModules SourceRaw    { sourceModName = n } = [n]


-- | this walks the loaded modules and ho files, discarding out of
-- date ho files and organizing modules into their binding groups.
-- the result is an acyclic graph where the nodes are ho files, sets
-- of mutually recursive modules, or libraries.
-- there is a strict ordering of
-- source >= ho >= library
-- in terms of dependencies


libModMap (Library _ libr _ _) = hoModuleMap libr

toCompUnitGraph :: Done -> [Module] -> IO CompUnitGraph
toCompUnitGraph done roots = do
    let fs m = map inject $ maybe (error $ "can't find deps for: " ++ show m) snd (Map.lookup m (knownSourceMap done))
        fs' m (Library _ libr _ _) = fromMaybe (error $ "can't find deps for: " ++ show m) (Map.lookup m (hoModuleDeps libr))
        foundMods = [ ((m,Left (sourceHash sc)),fs (sourceHash sc)) | (m,Found sc) <- Map.toList (modEncountered done)]
        foundMods' = Map.elems $ Map.fromList [ (mg,((mg,Right lib),fs' mg lib)) | (_,ModLibrary mg lib) <- Map.toList (modEncountered done)]
        fullModMap = Map.unions (map libModMap $ Map.elems (loadedLibraries done))
        inject m = Map.findWithDefault m m fullModMap
        gr = G.newGraph  (foundMods ++ foundMods') (fst . fst) snd
        gr' = G.sccGroups gr
        lmods = Map.mapMaybe ( \ x -> case x of ModLibrary mg lib -> Just (mg,lib) ; _ -> Nothing) (modEncountered done)
        phomap = Map.fromListWith (++) (concat [  [ (m,[hh]) | (m,_) <- hoDepends idep ] | (hh,(_,_,idep,_)) <- Map.toList (hosEncountered done)])
        sources = Map.fromList [ (m,sourceHash sc) | (m,Found sc) <- Map.toList (modEncountered done)]

   -- mapM_ (putErrLn . show) $ [ (x,y) | ((x,_),y) <- foundMods ++ foundMods' ]

    when (dump FD.SccModules) $ do
        mapM_ (putErrLn . show) $ map (map $ fst . fst) gr'
        putErrLn $ drawForest (map (fmap (show . fst . fst)) (G.dff gr))

    cug_ref <- newIORef []
    hom_ref <- newIORef (Map.map ((,) False) $ hosEncountered done)
    ms <- forM gr' $ \ns -> do
        r <- newIORef (Left ns)
        return (Map.fromList [ (m,r) | ((m,_),_) <- ns ])
    let mods = Map.unions ms
        lmods m = fromMaybe (error $ "modsLookup: " ++ show m) (Map.lookup m mods)
    let f m = do
            rr <- readIORef (lmods m)
            case rr of
                Right hh -> return hh
                Left ns -> g ns

        g ms@(((m,Left _),_):_) = do
            let amods = map (fst . fst) ms
            pm (fromMaybe [] (Map.lookup m phomap)) $ do
                let deps = Set.toList $ Set.fromList (concat $ snds ms) `Set.difference` (Set.fromList amods)
                deps' <- snub `fmap` mapM f deps
                let mhash = MD5.md5String (concatMap (show . fst) ms ++ show deps')
                writeIORef (lmods m) (Right mhash)
                modifyIORef cug_ref ((mhash,(deps',CompSources $ map fs amods)):)
                return mhash
        g [((mg,Right lib@(Library _ libr mhot mhob)),ds)] = do
                let Just mgs = Map.lookup mg (hoModuleDeps libr)
                    Just hob = Map.lookup mg mhob
                    Just hot = Map.lookup mg mhot
                    ho = Ho { hoModuleGroup = mg, hoBuild = hob, hoTcInfo = hot }
                    myHash = libMgHash mg lib
                deps <- snub `fmap` mapM f ds
                writeIORef (lmods mg) (Right myHash)
                modifyIORef cug_ref ((myHash,(deps,CompLibrary ho lib)):)
                return myHash
        pm :: [HoHash] -> IO HoHash -> IO HoHash
        pm [] els = els
        pm (h:hs) els = hvalid h `catch` (\_ -> pm hs els)
        hvalid h = do
            ll <- Map.lookup h `fmap` readIORef hom_ref
            case ll of
                Nothing -> fail "Don't know anything about this hash"
                Just (True,_) -> return h
                Just (False,af@(fp,hoh,idep,ho)) -> do
                    fp <- shortenPath fp
                    isGood <- catch ( mapM_ cdep (hoDepends idep) >> mapM_ hvalid (hoModDepends idep) >> return True) (\_ -> return False)
                    let isStale = not . null $ map (show . fst) (hoDepends idep) `intersect` optStale options
                        libsGood = all (\ (p,h) -> fmap (libHash) (Map.lookup p (loadedLibraries done)) == Just h) (hohLibDeps hoh)
                        noGood forced = do
                            putProgressLn $ printf "Stale: <%s>%s" fp forced
                            modifyIORef hom_ref (Map.delete h)
                            fail "stale file"
                    case (isStale,isGood && libsGood) of
                        (False,True) -> do
                            putProgressLn $ printf "Fresh: <%s>" fp
                            hs <- mapM f (hoModuleGroupNeeds idep)
                            modifyIORef cug_ref ((h,(hs ++ hoModDepends idep,CompHo hoh idep ho)):)
                            modifyIORef hom_ref (Map.insert h (True,af))
                            return h
                        (True,_) -> noGood " (forced)"
                        (_,False) -> noGood (show (isGood,libsGood))
        cdep (_,hash) | hash == MD5.emptyHash = return ()
        cdep (mod,hash) = case Map.lookup mod sources of
            Just hash' | hash == hash' -> return ()
            _ -> fail "Can't verify module up to date"
        fs m = case Map.lookup m (modEncountered done) of
            Just (Found sc) -> sc
            _ -> error $ "fs: " ++ show m
    mapM_ f (map inject roots)
    readIORef cug_ref

libHash (Library hoh _ _ _) = hohHash hoh
libMgHash mg lib = MD5.md5String $ show (libHash lib,mg)
libProvides mg (Library _ lib _ _) = [ m | (m,mg') <- Map.toList (hoModuleMap lib), mg == mg']

parseFiles :: [Either Module String]                                   -- ^ Either a module or filename to find
               -> (CollectedHo -> Ho -> IO CollectedHo)                -- ^ Process initial ho loaded from file
               -> (CollectedHo -> Ho -> TiData -> IO (CollectedHo,Ho)) -- ^ Process set of mutually recursive modules to produce final Ho
               -> IO (CompNode,CollectedHo)                            -- ^ Final accumulated ho

parseFiles need ifunc func = do
    putProgressLn "Finding Dependencies..."
    (ksm, needed,cug) <- loadModules (optHls options) need
    cnode <- processCug cug >>= mkPhonyCompNode needed
    performGC
    putProgressLn "Typechecking..."
    typeCheckGraph cnode
    performGC
    putProgressLn "Compiling..."
    cho <- compileCompNode ifunc func ksm cnode
    return (cnode,cho)


-- this takes a list of modules or files to load, and produces a compunit graph
loadModules :: [String]                 -- ^ libraries to load
            -> [Either Module String]   -- ^ a list of modules or filenames
            -> IO (Map.Map SourceHash (Module,[Module]),[Module],CompUnitGraph)  -- ^ the resulting acyclic graph of compilation units
loadModules libs need = do
    done_ref <- newIORef mempty
    unless (null libs) $ putProgressLn $ "Loading libraries:" <+> show libs
    forM_ (optHls options) $ \l -> do
        (n',fn) <- findLibrary l
        lib@(Library hoh libr _ _)  <- catch (readHlFile fn) $ \_ ->
            fail $ "Error loading library file: " ++ fn
        let Right (libName,libVers) = hohName hoh
        putProgressLn $ printf "Library: %-15s <%s>" n' fn
        modifyIORef done_ref (modEncountered_u $ Map.union (Map.fromList [ (m,ModLibrary mg lib) | (m,mg) <- Map.toList (hoModuleMap libr) ]))
        modifyIORef done_ref (loadedLibraries_u $ Map.insert libName lib)
    ms1 <- forM (rights need) $ \fn -> do
        fetchSource done_ref [fn] Nothing
    forM_ (lefts need) $ resolveDeps done_ref
    processIOErrors
    done <- readIORef done_ref
    let needed = (ms1 ++ lefts need)
    cug <- toCompUnitGraph done needed
    --mapM_ print [  (h,hs)| (h,(hs,cu)) <- cug ]
    return (Map.filterWithKey (\k _ -> k `Set.member` validSources done) (knownSourceMap done),needed,cug)



-- turn the list of CompUnits into a true mutable graph.
processCug :: CompUnitGraph -> IO [CompNode]
processCug cug = mdo
    let mmap = Map.fromList xs
        lup x = maybe (error $ "processCug: " ++ show x) id (Map.lookup x mmap)
        f (h,(ds,cu)) = do
            cur <- newIORef (CompLinkUnit cu)
            return $ (h,CompNode h (map lup ds) cur)
    xs <- mapM f cug
    return $ snds xs


-- take the list of CompNodes and what modules we want and create a root node
-- that will reach all dependencies when compiled.

mkPhonyCompNode :: [Module] -> [CompNode] -> IO CompNode
mkPhonyCompNode need cs = do
    xs <- forM cs $ \cn@(CompNode _ _ cu) -> readIORef cu >>= \u -> return $ if null $ providesModules u `intersect` need then [] else [cn]
    let hash = MD5.md5String $ show [ h | CompNode h _ _ <- concat xs ]
    CompNode hash (concat xs) `fmap` newIORef (CompLinkUnit CompDummy)

printModProgress :: Int -> Int -> IO Int -> [HsModule] -> IO ()
printModProgress _ _ _ [] = return ()
printModProgress _ _ tickProgress ms | not progress = mapM_ (const tickProgress) ms
printModProgress fmtLen maxModules tickProgress ms = f "[" ms where
    f bl ms = do
        curModule <- tickProgress
        case ms of
            [x] -> g curModule bl "]" x
            (x:xs) -> do g curModule bl "-" x; putErrLn ""; f "-" xs
    g curModule bl el modName = putErr $ printf "%s%*d of %*d%s %-17s" bl fmtLen curModule fmtLen maxModules el (show $ hsModuleName modName)


countNodes cn = do
    seen <- newIORef Set.empty
    let h (CompNode hh deps ref) = do
            s <- readIORef seen
            if hh `Set.member` s then return Set.empty else do
                writeIORef seen (Set.insert hh s)
                ds <- mapM h deps
                cm <- readIORef ref >>= g
                return (Set.unions (cm:ds))
        g cn = case cn of
            CompLinkUnit cu      -> return $ f cu
            CompTcCollected _ cu -> return $ f cu
            CompCollected _ cu   -> return $ f cu
        f cu = case cu of
            CompTCed (_,_,_,ss) -> Set.fromList ss
            CompSources sc      -> Set.fromList (map sourceIdent sc)
            _                   -> Set.empty
    h cn


typeCheckGraph :: CompNode -> IO ()
typeCheckGraph cn = do
    cur <- newMVar (1::Int)
    maxModules <- Set.size `fmap` countNodes cn
    let f (CompNode hh deps ref) = readIORef ref >>= \cn -> case cn of
            CompTcCollected ctc _ -> return ctc
            CompLinkUnit lu -> do
                deps' <- randomPermuteIO deps
                ctc <- mconcat `fmap` mapM f deps'
                case lu of
                    CompDummy -> do
                        writeIORef ref (CompTcCollected ctc CompDummy)
                        return ctc
                    CompHo hoh idep ho  -> do
                        let ctc' = hoTcInfo ho `mappend` ctc
                        writeIORef ref (CompTcCollected ctc' lu)
                        return ctc'
                    CompLibrary ho _libr  -> do
                        let ctc' = hoTcInfo ho `mappend` ctc
                        writeIORef ref (CompTcCollected ctc' lu)
                        return ctc'
                    CompSources sc -> do
                        modules <- forM sc $ \x -> case x of
                            SourceParsed { sourceHash = h,sourceModule = mod } -> return (h,mod)
                            SourceRaw { sourceHash = h,sourceLBS = lbs, sourceFP = fp } -> do
                                mod <- parseHsSource fp lbs
                                return (h,mod)
                        showProgress (snds modules)
                        (htc,tidata) <- doModules' ctc (snds modules)
                        let ctc' = htc `mappend` ctc
                        writeIORef ref (CompTcCollected ctc' (CompTCed ((htc,tidata,modules,map sourceHoName sc))))
                        return ctc'
        showProgress ms = printModProgress fmtLen maxModules tickProgress ms
        fmtLen = ceiling (logBase 10 (fromIntegral maxModules+1) :: Double) :: Int
        tickProgress = modifyMVar cur $ \val -> return (val+1,val)
    f cn
    return ()

compileCompNode :: (CollectedHo -> Ho -> IO CollectedHo)                 -- ^ Process initial ho loaded from file
                -> (CollectedHo -> Ho -> TiData  -> IO (CollectedHo,Ho)) -- ^ Process set of mutually recursive modules to produce final Ho
                -> Map.Map SourceHash (Module,[Module])
                -> CompNode
                -> IO CollectedHo
compileCompNode ifunc func ksm cn = do
    cur <- newMVar (1::Int)
    ksm_r <- newIORef ksm
    let tickProgress = modifyMVar cur $ \val -> return (val+1,val)
    maxModules <- Set.size `fmap` countNodes cn
    let showProgress ms = printModProgress fmtLen maxModules tickProgress ms
        fmtLen = ceiling (logBase 10 (fromIntegral maxModules+1) :: Double) :: Int
    let f (CompNode hh deps ref) = readIORef ref >>= g where
            g cn = case cn of
                CompCollected ch _ -> return ch
                CompTcCollected _ cl -> h cl
                CompLinkUnit cu -> h cu
            h cu = do
                deps' <- randomPermuteIO deps
                cho <- mconcat `fmap` mapM f deps'

                case cu of
                    CompDummy -> do
                        writeIORef ref (CompCollected cho CompDummy)
                        return cho
                    (CompHo hoh idep ho) -> do
                        cho <- ifunc cho ho
                        writeIORef ref (CompCollected cho cu)
                        return cho
                    (CompLibrary ho (Library hoh _ _ _)) -> do
                        cho <- ifunc cho ho
                        let Right (ln,_) = hohName hoh
                            lh = hohHash hoh
                        writeIORef ref (CompCollected (choLibDeps_u (Map.insert ln lh) cho) cu)
                        return cho
                    CompTCed ((htc,tidata,modules,shns))  -> do
                        (hdep,ldep) <- fmap mconcat . forM deps $ \ (CompNode h _ ref) -> do
                            cl <- readIORef ref
                            case compLinkCompUnit cl of
                                CompLibrary ho _ -> return ([],[hoModuleGroup ho])
                                CompDummy {} -> return ([],[])
                                _ -> return ([h],[])
                        showProgress (snds modules)
                        let (mgName:_) = sort $ map (hsModuleName . snd) modules
                        (cho',newHo) <- func cho mempty { hoModuleGroup = mgName, hoTcInfo = htc } tidata
                        modifyIORef ksm_r (Map.union $ Map.fromList [ (h,(hsModuleName mod,hsModuleRequires mod)) | (h,mod) <- modules])
                        ksm <- readIORef ksm_r
                        let hoh = HoHeader {
                                     hohVersion = error "hohVersion",
                                     hohName = Left mgName,
                                     hohHash       = hh,
                                     hohArchDeps = [],
                                     hohLibDeps   = Map.toList (choLibDeps cho')
                                     }
                            idep = HoIDeps {
                                    hoIDeps =    ksm,
                                    hoDepends    = [ (hsModuleName mod,h) | (h,mod) <- modules],
                                    hoModDepends = hdep,
                                    hoModuleGroupNeeds = ldep
                                    }
                        recordHoFile (mapHoBodies eraseE newHo) idep shns hoh
                        writeIORef ref (CompCollected cho' (CompHo hoh idep newHo))
                        return cho'
                    CompSources _ -> error "sources still exist!?"
    f cn





hsModuleRequires x = snub (Module "Jhc.Prim":ans) where
    noPrelude =   or $ not (optPrelude options):[ opt == c | opt <- hsModuleOptions x, c <- ["-N","--noprelude"]]
    ans = (if noPrelude then id else  (Module "Prelude":)) [  hsImportDeclModule y | y <- hsModuleImports x]

searchPaths :: String -> [(String,String)]
searchPaths m = ans where
    f m | (xs,'.':ys) <- span (/= '.') m = let n = (xs ++ "/" ++ ys) in m:f n
        | otherwise = [m]
    ans = [ (root ++ suf,root ++ ".ho") | i <- optIncdirs options, n <- f m, suf <- [".hs",".lhs"], let root = i ++ "/" ++ n]


m4Prelude :: IO FilePath
m4Prelude = writeFile "/tmp/jhc_prelude.m4" prelude_m4 >> return "/tmp/jhc_prelude.m4"

langmap = [
    "m4" ==> "m4",
    "cpp" ==> "cpp",
    "foreignfunctioninterface" ==> "ffi",
    "noimplicitprelude" ==> "--noprelude",
    "unboxedtuples" ==> "unboxed-tuples"
    ] where x ==> y = (x,if head y == '-' then y else "-f" ++ y)


parseHsSource :: String -> LBS.ByteString -> IO HsModule
parseHsSource fn lbs = do
    let txt = LBS.toString lbs
    let f s = opt where
            Just opt = fileOptions opts `mplus` Just options
            popts = parseOptions $ if "shl." `isPrefixOf` reverse fn  then unlit fn s else s
            opts' = concat [ words as | (x,as) <- popts, x `elem` ["OPTIONS","JHC_OPTIONS","OPTIONS_JHC"]]
            opts = opts' ++ [ "--noprelude" | ("NOPRELUDE",_) <- popts] ++ langs
            langs = catMaybes $ map (flip lookup langmap) $ concat [ words (map (\c -> if c == ',' then ' ' else toLower c) as) | ("LANGUAGE",as) <- popts ]
    let fopts s = s `member` optFOptsSet initialOpts
        initialOpts = f (take 4096 txt)
        incFlags = [ "-I" ++ d | d <- optIncdirs options ++ optIncs initialOpts]
        defFlags = ("-D__JHC__=" ++ revision):[ "-D" ++ d | d <- optDefs initialOpts]

    s <- case () of
        _ | fopts FO.Cpp -> readSystem "cpp" $ ["-CC","-traditional"] ++ incFlags ++ defFlags ++ [fn]
          | fopts FO.M4 -> do
            m4p <- m4Prelude
            readSystem "m4" $ ["-s", "-P"] ++ incFlags ++ defFlags ++ [m4p,fn]
          | otherwise -> return txt
    let s' = if "shl." `isPrefixOf` reverse fn  then unlit fn s'' else s''
        s'' = case s of
            '#':' ':_   -> '\n':s                --  line pragma
            '#':'l':'i':'n':'e':' ':_  -> '\n':s --  line pragma
            '#':'!':_ -> dropWhile (/= '\n') s   --  hashbang
            _ -> s
    wdump FD.Preprocessed $ do
        putStrLn s'
    fn <- shortenPath fn
    case runParserWithMode (parseModeOptions $ f s) { parseFilename = fn } parse  s'  of
                      ParseOk ws e -> processErrors ws >> return e
                      ParseFailed sl err -> putErrDie $ show sl ++ ": " ++ err


mapHoBodies  :: (E -> E) -> Ho -> Ho
mapHoBodies sm ho = ho { hoBuild = g (hoBuild ho) } where
    g ho = ho { hoEs = map f (hoEs ho) , hoRules =  runIdentity (E.Rules.mapBodies (return . sm) (hoRules ho)) }
    f (t,e) = (t,sm e)


eraseE :: E -> E
eraseE e = runIdentity $ f e where
    f (EVar tv) = return $ EVar  tvr { tvrIdent = tvrIdent tv }
    f e = emapE f e



---------------------------------
-- library specific routines
---------------------------------



buildLibrary :: (CollectedHo -> Ho -> IO CollectedHo)
             -> (CollectedHo -> Ho -> TiData -> IO (CollectedHo,Ho)) -- ^ Process set of mutually recursive modules to produce final Ho
             -> FilePath
             -> IO ()
buildLibrary ifunc func = ans where
    ans fp = do
        (desc,name,vers,hmods,emods) <- parse fp
        vers <- runReadP parseVersion vers
        let allmods = snub (emods ++ hmods)
        -- TODO - must check we depend only on libraries
        (rnode@(CompNode lhash _ _),cho) <- parseFiles (map Left allmods) ifunc func
        (_,(mmap,mdeps,prvds,lcor,ldef)) <- let
            f (CompNode hs cd ref) = do
                cl <- readIORef ref
                case cl of
                    CompLinkLib l _ -> return l
                    CompCollected _ y -> g hs cd ref y
            g hh deps ref cn = do
                deps <- mapM f deps
                let (mg,mll) = case cn of
                        CompDummy -> (error "modgroup of dummy",mempty)
                        CompLibrary ho lib -> (hoModuleGroup ho,mempty)
                        CompHo hoh hidep ho -> (mg,(
                                    Map.fromList $ zip (providesModules hidep) (repeat mg),
                                    Map.singleton mg (sort $ fsts deps),
                                    Set.fromList $ providesModules hidep,
                                    Map.singleton mg (hoBuild ho'),
                                    Map.singleton mg (hoTcInfo ho')
                                    )) where
                                        mg = hoModuleGroup ho
                                        ho' = mapHoBodies eraseE ho
                    res = (mg,mconcat (snds deps) `mappend` mll)
                writeIORef ref (CompLinkLib res cn)
                return res
          in f rnode
        let unknownMods = Set.toList $ Set.filter (`notElem` allmods) prvds
        mapM_ ((putStrLn . ("*** Module included in library that is not in export list: " ++)) . show) unknownMods
        let hoh =  HoHeader {
                hohHash = lhash,
                hohName = Right (packString name,vers),
                hohLibDeps = Map.toList (choLibDeps cho),
                hohArchDeps = [],
                hohVersion = error "hohVersion"
                }
        let outName = case optOutName options of
                Nothing -> name ++ "-" ++ showVersion vers ++ ".hl"
                Just fn -> fn
        let pdesc = [(n, packString v) | (n,v) <- ("jhc-hl-filename",outName):("jhc-description-file",fp):("jhc-compiled-by",versionString):desc, n /= "exposed-modules" ]
            libr = HoLib {
                hoMetaInfo = pdesc,
                hoModuleMap = mmap,
                hoModuleDeps = mdeps
                }
        putProgressLn $ "Writing Library: " ++ outName
        recordHlFile (Library hoh libr ldef lcor) outName
    -- parse library description file
    parse fp = do
        putProgressLn $ "Creating library from description file: " ++ show fp
        desc <- readDescFile fp
        when verbose2 $ mapM_ print desc
        let field x = lookup x desc
            jfield x = maybe (fail $ "createLibrary: description lacks required field " ++ show x) return $ field x
            mfield x = maybe [] (words . map (\c -> if c == ',' then ' ' else c)) $ field x
        name <- jfield "name"
        vers <- jfield "version"
        let hmods = map Module $ snub $ mfield "hidden-modules"
            emods = map Module $ snub $ mfield "exposed-modules"
        return (desc,name,vers,hmods,emods)

--collectLibraries :: IO [FilePath]
--collectLibraries = concat `fmap` mapM f (optHlPath options) where
--    f fp = do
--        fs <- flip catch (\_ -> return []) $ getDirectoryContents fp
--        flip mapM fs $ \e -> case reverse e of
--            ('l':'h':'.':r)  -> do
--                (fn',hoh,mp) <- readHFile (fp++"/"++e)
--
--        _               -> []


------------------------------------
-- dumping contents of a ho file
------------------------------------

instance DocLike d => PPrint d MD5.Hash where
    pprint h = tshow h

instance DocLike d => PPrint d SrcLoc where
    pprint sl = tshow sl

instance DocLike d => PPrint d Version where
    pprint sl = text $ showVersion sl

instance DocLike d => PPrint d PackedString where
    pprint sl = text (unpackPS sl)

{-# NOINLINE dumpHoFile #-}
dumpHoFile :: String -> IO ()
dumpHoFile fn = ans where
    ans = do
        putStrLn fn
        case reverse fn of
            'l':'h':'.':_ -> doHl fn
            'o':'h':'.':_ -> doHo fn
    vindent xs = vcat (map ("    " ++) xs)
    showList nm xs = when (not $ null xs) $ putStrLn $ (nm ++ ":\n") <>  vindent xs
    doHoh hoh = do
        putStrLn $ "Version:" <+> pprint (hohVersion hoh)
        putStrLn $ "Hash:" <+> pprint (hohHash hoh)
        putStrLn $ "Name:" <+> pprint (hohName hoh)
        showList "LibDeps" (map pprint . sortUnder fst $ hohLibDeps hoh)
        showList "ArchDeps" (map pprint . sortUnder fst $ hohArchDeps hoh)

    doHl fn = do
        Library hoh libr mhob mhot <- readHlFile fn
        doHoh hoh
        showList "MetaInfo" (sort [text k <> char ':' <+> show v | (k,v) <- hoMetaInfo libr])
        showList "ModuleMap" (map pprint . sortUnder fst $ Map.toList $ hoModuleMap libr)
        showList "ModuleDeps" (map pprint . sortUnder fst $ Map.toList $ hoModuleDeps libr)

    doHo fn = do
        (hoh,idep,ho) <- readHoFile fn
        doHoh hoh
        let hoB = hoBuild ho
            hoE = hoTcInfo ho
        showList "Dependencies" (map pprint . sortUnder fst $ hoDepends idep)
        showList "ModDependencies" (map pprint $ hoModDepends idep)
        showList "IDepCache" (map pprint . sortUnder fst $ Map.toList $ hoIDeps idep)
    --    when (not $ Prelude.null (hohMetaInfo hoh)) $ putStrLn $ "MetaInfo:\n" <> vindent (sort [text (' ':' ':k) <> char ':' <+> show v | (k,v) <- hohMetaInfo hoh])
        putStrLn $ "Modules contained:" <+> tshow (mkeys $ hoExports hoE)
        putStrLn $ "number of definitions:" <+> tshow (size $ hoDefs hoE)
        putStrLn $ "hoAssumps:" <+> tshow (size $ hoAssumps hoE)
        putStrLn $ "hoFixities:" <+> tshow (size $  hoFixities hoE)
        putStrLn $ "hoKinds:" <+> tshow (size $  hoKinds hoE)
        putStrLn $ "hoClassHierarchy:" <+> tshow (size $  hoClassHierarchy hoE)
        putStrLn $ "hoTypeSynonyms:" <+> tshow (size $  hoTypeSynonyms hoE)
        putStrLn $ "hoDataTable:" <+> tshow (size $  hoDataTable hoB)
        putStrLn $ "hoEs:" <+> tshow (size $  hoEs hoB)
        putStrLn $ "hoRules:" <+> tshow (size $  hoRules hoB)
        wdump FD.Exports $ do
            putStrLn "---- exports information ----";
            CharIO.putStrLn $  (pprint $ hoExports hoE :: String)
        wdump FD.Defs $ do
            putStrLn "---- defs information ----";
            CharIO.putStrLn $  (pprint $ hoDefs hoE :: String)
        when (dump FD.Kind) $ do
            putStrLn "---- kind information ----";
            CharIO.putStrLn $  (pprint $ hoKinds hoE :: String)
        when (dump FD.ClassSummary) $ do
            putStrLn "---- class summary ---- "
            printClassSummary (hoClassHierarchy hoE)
        when (dump FD.Class) $
             do {putStrLn "---- class hierarchy ---- ";
                 printClassHierarchy (hoClassHierarchy hoE)}
        let rules = hoRules hoB
        wdump FD.Rules $ putStrLn "  ---- user rules ---- " >> printRules RuleUser rules
        wdump FD.Rules $ putStrLn "  ---- user catalysts ---- " >> printRules RuleCatalyst rules
        wdump FD.RulesSpec $ putStrLn "  ---- specializations ---- " >> printRules RuleSpecialization rules
        wdump FD.Datatable $ do
             putStrLn "  ---- data table ---- "
             putDocM CharIO.putStr (showDataTable (hoDataTable hoB))
             putChar '\n'
        wdump FD.Types $ do
            putStrLn " ---- the types of identifiers ---- "
            putStrLn $ PPrint.render $ pprint (hoAssumps hoE)
        wdump FD.Core $ do
            putStrLn " ---- lambdacube  ---- "
            mapM_ (\ (v,lc) -> putChar '\n' >> printCheckName'' (hoDataTable hoB) v lc) (hoEs hoB)
        where
        printCheckName'' :: DataTable -> TVr -> E -> IO ()
        printCheckName'' _dataTable tvr e = do
            when (dump FD.EInfo || verbose2) $ putStrLn (show $ tvrInfo tvr)
            putStrLn (render $ hang 4 (pprint tvr <+> text "::" <+> pprint (tvrType tvr)))
            putStrLn (render $ hang 4 (pprint tvr <+> equals <+> pprint e))

