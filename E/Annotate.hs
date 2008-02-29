module E.Annotate where

import Control.Monad.Reader
import Data.Monoid
import qualified Data.Traversable as T

import E.E
import E.Program
import E.Rules
import E.Subst
import GenUtil
import Info.Types
import Name.Id
import qualified Info.Info as Info
import Info.Info(Info)
import Util.SetLike
import Util.HasSize

annotateCombs :: Monad m =>
    (IdMap (Maybe E))
    -> (Id -> Info -> m Info)   -- ^ annotate based on Id map
    -> (E -> Info -> m Info) -- ^ annotate letbound bindings
    -> (E -> Info -> m Info) -- ^ annotate lambdabound bindings
    -> [Comb]            -- ^ terms to annotate
    -> m [Comb]

annotateCombs imap idann letann lamann ds = do

    cs <- forM ds $ \comb -> do
        nfo <- letann (combBody comb) (tvrInfo $ combHead comb)
        nt <- annotate imap idann letann lamann (tvrType  $ combHead comb)
        return $ combHead_u (tvrInfo_s nfo . tvrType_s nt) comb
    let nimap = fromList [ (combIdent c, Just . EVar $ combHead c) | c <- cs ] `mappend` imap
    cs <- forM cs $ \comb -> do
        rs <- forM (combRules comb) $ \r -> do
            r' <- annotate nimap idann letann lamann $ ruleBody r
            return r { ruleBody = r' }
        nb <- annotate nimap idann letann lamann (combBody comb)
        return . combRules_s rs . combBody_s nb $ comb
    return cs


    --let ds' = [ (combHead c,combBody c) | c <- ds]
    --ELetRec { eDefs = ds'', eBody = Unknown } <- annotate imap idann letann lamann (ELetRec ds' Unknown)
    -- TODO. slow
    --return [ combBody_s y . combHead_s x $ c | c <- ds, (x,y) <- ds'', x == combHead c]

annotateDs :: Monad m =>
    (IdMap (Maybe E))
    -> (Id -> Info -> m Info)   -- ^ annotate based on Id map
    -> (E -> Info -> m Info) -- ^ annotate letbound bindings
    -> (E -> Info -> m Info) -- ^ annotate lambdabound bindings
    -> [(TVr,E)]            -- ^ terms to annotate
    -> m [(TVr,E)]

annotateDs imap idann letann lamann ds = do
    ELetRec { eDefs = ds', eBody = Unknown } <- annotate imap idann letann lamann (ELetRec ds Unknown)
    return ds'

annotateProgram :: Monad m =>
    (IdMap (Maybe E))
    -> (Id -> Info -> m Info)   -- ^ annotate based on Id map
    -> (E -> Info -> m Info)    -- ^ annotate letbound bindings
    -> (E -> Info -> m Info)    -- ^ annotate lambdabound bindings
    -> Program                -- ^ terms to annotate
    -> m Program
annotateProgram imap idann letann lamann prog = do
    ds <- annotateCombs imap idann letann lamann (progCombinators prog)
    return $ programUpdate $ prog { progCombinators = ds }


annotate :: Monad m =>
    (IdMap (Maybe E))
    -> (Id -> Info -> m Info)   -- ^ annotate based on Id map
    -> (E -> Info -> m Info) -- ^ annotate letbound bindings
    -> (E -> Info -> m Info) -- ^ annotate lambdabound bindings
    ->  E            -- ^ term to annotate
    -> m E
annotate imap idann letann lamann e = runReaderT (f e) imap where
    f eo@(EVar tvr@(TVr { tvrIdent = i, tvrType =  t })) = do
        mp <- ask
        case mlookup i mp of
          Just (Just v) -> return v
          _  -> return eo
    f (ELam tvr e) = lp LambdaBound ELam tvr e
    f (EPi tvr e) = lp PiBound EPi tvr e
    f (EAp a b) = liftM2 EAp (f a) (f b)
    f (EError x e) = liftM (EError x) (f e)
    f (EPrim x es e) = liftM2 (EPrim x) (mapM f es) (f e)
    f ELetRec { eDefs = dl, eBody = e } = do
        dl' <- flip mapM dl $ \ (t,e) -> do
            nfo <- lift $ letann e (tvrInfo t)
            return t { tvrInfo = nfo }
        (as,rs) <- liftM unzip $ mapMntvr dl'
        local (foldr (.) id rs) $ do
            as <- mapM procRules as
            ds <- mapM f (snds dl)
            e' <- f e
            return $ ELetRec (zip as ds) e'
    f (ELit l) = liftM ELit $ litSMapM f l
    f Unknown = return Unknown
    f e@(ESort {}) = return e
    f ec@(ECase {}) = do
        e' <- f $ eCaseScrutinee ec
        let caseBind = eCaseBind ec
        caseBind <- procRules caseBind
        (b',r) <- ntvr [] caseBind
        d <- local r $ T.mapM f $ eCaseDefault ec
        let da (Alt lc@LitCons { litName = s, litArgs = vs, litType = t } e) = do
                t' <- f t
                (as,rs) <- liftM unzip $ mapMntvr vs
                e' <- local (foldr (.) id rs) $ f e
                return $ Alt lc { litArgs = as, litType = t' } e'
            da (Alt l e) = do
                l' <- T.mapM f l
                e' <- f e
                return $ Alt l' e'
        alts <- local r (mapM da $ eCaseAlts ec)
        t' <- f (eCaseType ec)
        return $ caseUpdate ECase { eCaseAllFV = error "no eCaseAllFV needed",  eCaseScrutinee = e', eCaseType = t', eCaseDefault = d, eCaseBind = b', eCaseAlts = alts }
    lp bnd lam tvr@(TVr { tvrIdent = n, tvrType = t}) e | n == 0  = do
        t' <- f t
        tvr <- procRules tvr
        nfo <- lift $ lamann e (tvrInfo tvr)
        nfo <- lift $ idann n nfo
        e' <- local (minsert n Nothing) $ f e
        return $ lam (tvr { tvrIdent =  0, tvrType =  t', tvrInfo =  nfo}) e'
    lp bnd lam tvr e = do
        nfo <- lift $ lamann e (tvrInfo tvr)
        (tv,r) <- ntvr  [] tvr { tvrInfo = nfo }
        e' <- local r $ f e
        return $ lam tv e'
    mapMntvr ts = f ts [] where
        f [] xs = return $ reverse xs
        f (t:ts) rs = do
            (t',r) <- ntvr vs t
            local r $ f ts ((t',r):rs)
        vs = [ tvrIdent x | x <- ts ]
    ntvr xs tvr@(TVr { tvrIdent = 0, tvrType =  t}) = do
        t' <- f t
        tvr <- procRules tvr
        nfo <- lift $ idann 0 (tvrInfo tvr)
        let nvr = (tvr { tvrType =  t', tvrInfo = nfo})
        return (nvr,id)
    ntvr xs tvr@(TVr {tvrIdent = i, tvrType =  t}) = do
        t' <- f t
        ss <- ask
        tvr <- procRules tvr
        nfo' <- lift $ idann i (tvrInfo tvr)
        let i' = mnv xs i ss
        let nvr = (tvr { tvrIdent =  i', tvrType =  t', tvrInfo =  nfo'})
        case i == i' of
            True -> return (nvr,minsert i (Just $ EVar nvr))
            False -> return (nvr,minsert i (Just $ EVar nvr) . minsert i' Nothing)
    mrule r = do
        let g tvr = do
            nfo <- lift $ idann (tvrIdent tvr) (tvrInfo tvr)
            return (tvr { tvrInfo = nfo },minsert (tvrIdent tvr) (Just $ EVar tvr))
        bs <- mapM g $ ruleBinds r
        local (foldr (.) id $ snds bs) $ do
            args <- mapM f (ruleArgs r)
            body <- f (ruleBody r)
            return r { ruleBinds = fsts bs, ruleBody = body, ruleArgs = args }
    procRules tvr = case Info.lookup (tvrInfo tvr) of
        Nothing -> return tvr
        Just r -> do
            r' <- mapRules mrule r
            return tvr { tvrInfo = Info.insert r' (tvrInfo tvr) }

mnv xs i ss
    | isInvalidId i || i `mmember` ss  = newId (size ss) isOkay
    | otherwise = i
    where isOkay i = (i `mnotMember` ss) && (i `notElem` xs)


