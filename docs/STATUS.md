# CorePad · état des contrats (2026-10-05)

Lectures on-chain faites le 2026-10-05 13:00 UTC sur Elysium testnet (chain 99801, bloc 3 112 847).

## Déployé (Elysium testnet)

| Contrat | Adresse | Rôle |
|---|---|---|
| CorePadFactory | `0x8547e759715b1bbd67291e06395E0C5FfeA4de13` | crée token + pool, symboles uniques, 13 tickers réservés |
| Settlement | `0x2cde65C326E61cD9619F4f4f08D20Eac0015559C` | tickets de graduation, dispatch / confirm / abort |
| ElysiumBridgeAdapter | `0x9BAA610A43B8f62F0d014aF4EEFB0dF44AF87e37` | tokens par le pont mirror, HYPE par `withdrawEth` |
| Dev (deployer, treasury, keeper, coreSettler) | `0x0d2246121587C62f0e97a3E96f17f58824324310` | clé unique, testnet seulement |

Paramètres : graduation 0,4 HYPE, ticker reserve 0,1 HYPE, frais 1 % du côté HYPE vers la treasury,
garde de lancement 60 s, abort possible 7 jours après la graduation. Le bytecode est présent aux 3 adresses
et Settlement pointe bien sur la Factory. Les sources ne sont vérifiées sur aucun explorer : aucun n'est
configuré dans le repo.

## Ce qui marche en live

- **Launch** : 1 lancement, TEST1 (token `0x78365c05…Bd18`, pool `0xb82d7323`). Le wallet escrow du pont est
  créé au lancement.
- **Courbe** : les achats ont porté TEST1 jusqu'à la graduation, avec 1 % de frais envoyé à la treasury.
  Les ventes et l'achat rogné puis remboursé sont couverts par les tests, pas re-vérifiés en live ici.
- **Graduation** : TEST1 est gradué. Le ticket #1 est `Open` : Settlement tient 0,4 HYPE (`lockedHype`) et
  200 M TEST1 (`lockedTokens`).
- **App** : https://corepad.app branchée sur ces adresses.

## Prouvé en test, pas encore exécuté en live

- **Dispatch** (tokens par le pont mirror, HYPE par `withdrawEth`) : passe sur fork Elysium avec les vrais
  contrats du pont (290 683 gas) et dans la répétition anvil. Bloqué en live parce que le mirror de TEST1
  doit être enregistré sur HyperEVM testnet et que le dev y a 0 HYPE.
- **Abort** (le pool rouvre, les holders revendent, nouvelle graduation possible) : passe en test et sur
  anvil. En live, le délai est **passé** (depuis le 2026-10-04 02:21:39 UTC) : n'importe qui peut appeler `abort(1)` dès maintenant. Personne ne l'a fait, le ticket #1 est toujours `Open`.
- **Confirm** (keeper) et claim sur l'Outbox HyperEVM : codés dans `ops/keeper`, jamais lancés en live.
- **Sweep** du surplus non compté (Settlement, adapter, pool graduée) : testé, jamais appelé en live.

## Ce qui ne peut pas marcher aujourd'hui (hors contrats)

- **Cotation HyperCore** : le ticker HIP-1 testnet coûte ~1 260 à 1 440 HYPE contre 0,1 HYPE de réserve, et
  la factory des deposit wallets HyperEVM → HyperCore n'est pas publiée.
- **ElysiumCoreWriter** et le precompile de market data : pas sortis. `coreWriterAdapter` est réservé,
  inutilisé en v0.

## Qualité

- `forge test` relancé le 2026-10-01 : **71 passés, 0 échec**, 4 tests fork ignorés (ils demandent
  `ELYSIUM_FORK=true` et passaient le 09-27, donc 75 en tout).
- Fuzz à 1 000 runs, 11 invariants, **34/34 mutants tués**, répétition e2e anvil complète (launch →
  graduate → abort → revente → re-graduate → dispatch → confirm).
- Audit du 09-27 (`docs/AUDIT.md`) : 0 critique, 0 haute. Corrigés : M-1, M-2, M-4, L-1, L-2, L-3, L-5.

## Risques ouverts

- **M-3** : une fois dispatché, il n'y a plus de retour on-chain. Les fonds sont alors sous la garde du
  keeper/coreSettler, qui est une EOA.
- **L-4** : une seule clé fait deployer, treasury, keeper et coreSettler, et cette clé a circulé en clair.
  Ça passe sur testnet. Pour le mainnet, il faut une multisig pour la treasury, un keeper dédié et une clé neuve.
- Le pitch « sans humain » ne tient pas encore : la cotation HIP-1 est une signature L1 faite par un keeper.

## Pour finir le cycle testnet

1. Envoyer ~0,05 HYPE sur HyperEVM testnet au dev `0x0d22…4310`.
2. `createAndRegisterL1Mirror` pour TEST1, puis attendre que la route soit prête sur Elysium.
3. `dispatch(1)`, puis claim sur l'Outbox par le keeper après la période de contestation.
4. S'arrêter là : la cotation sur HyperCore reste bloquée (voir plus haut).
