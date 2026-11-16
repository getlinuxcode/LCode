# LCode — Architecture

LCode est un IDE natif Linux (GTK4 / libadwaita) inspiré d'Xcode, pour développer
des apps Apple (iOS, iPadOS, macOS, tvOS) en Swift / SwiftUI sans Mac.

## Principes

1. **Build réel = xtool.** Toute compilation pour un appareil Apple passe par
   [xtool](https://github.com/xtool-org/xtool) (SDK iOS extrait d'un `Xcode.xip`
   fourni par l'utilisateur, signature, installation sur appareil).
2. **Simulateur = recompilation native Linux (approche B).** Le même code source
   est compilé une seconde fois pour Linux, contre **LSimUI**, une
   réimplémentation de l'API SwiftUI qui dessine dans une fenêtre imitant
   l'appareil cible. On n'émule pas iOS : on reproduit le comportement SwiftUI.
3. **Natif.** Interface GTK4 + libadwaita, pilotée depuis Swift.

## Modules (SwiftPM)

```
LCode/
├── Package.swift
├── Sources/
│   ├── LSimUI/          API publique compatible SwiftUI (View, Text, VStack,
│   │                    Button, @State, modifiers…) + moteur de layout.
│   │                    Aucune dépendance graphique : produit un arbre de
│   │                    rendu (display list) indépendant du backend.
│   ├── CGtk/            module map système vers GTK4 / Cairo / Pango.
│   ├── LSimRender/      backend Cairo/Pango : display list → pixels.
│   ├── LSimDevice/      profils d'appareils (taille en points, échelle,
│   │                    safe areas, coins arrondis, encoche / Dynamic Island).
│   ├── LSimHost/        fenêtre du simulateur : cadre de l'appareil,
│   │                    boucle d'événements, souris → touch, rotation, thème.
│   ├── LCodeKit/        cœur de l'IDE : projets, intégration xtool,
│   │                    sourcekit-lsp, génération du build « simulateur ».
│   └── LCode/           application GTK (éditeur, navigateur, console…).
└── Examples/            apps SwiftUI de test pour comparer avec le vrai simulateur.
```

## Pipeline du simulateur

```
Projet utilisateur (SwiftUI)
        │  LCodeKit génère un package Linux temporaire :
        │  - mêmes sources
        │  - `import SwiftUI`  → module LSimUI (via un module nommé SwiftUI)
        │  - point d'entrée @main App → LSimHost
        ▼
swift build (toolchain Linux) ──► exécutable natif
        ▼
LSimHost : App → Scene → View tree
        ▼
LSimUI  : résolution des body, état (@State/@Observable), layout
        ▼
Display list ──► LSimRender (Cairo/Pango) ──► fenêtre GTK habillée en iPhone
```

## Fidélité — ce qui compte

- **Layout** : algorithme de proposition de taille de SwiftUI (parent propose,
  enfant choisit, parent place), spacing par défaut, priorités de layout,
  `Spacer`, `frame`, `padding` (16 pt par défaut), safe areas.
- **Typographie** : styles Dynamic Type (`.body` = 17 pt, `.largeTitle` = 34 pt…),
  polices SF extraites localement (jamais redistribuées), repli sur une police libre.
- **Couleurs système** : `accentColor` = systemBlue, labels primaire/secondaire,
  fonds groupés, en clair et en sombre.
- **Composants** : NavigationStack, List, TabView, sheet, alert, Form, Toggle…
- **Animations** : courbes par défaut (spring), transitions.

## Banc de calibration

La fidélité ne repose pas sur des captures faites à la main mais sur des mesures exactes :

1. `Examples/Shared/Catalog/` : un catalogue SwiftUI (toutes les variantes d'un composant,
   chacune avec un identifiant) compilé à la fois pour iOS (xtool) et pour LSim.
2. Sur iPhone, l'app **LCode Catalogue** s'auto-inspecte page par page, en clair et en sombre :
   cadres calculés par SwiftUI (`onGeometryChange`), couches Core Animation (rayons, courbes,
   couleurs converties en sRVB, filtres, ombres) et capture sRVB, envoyés au PC.
3. `tools/calibration/receiver.py` reçoit les mesures ; `tools/calibration/compare.py` fait rendre
   les mêmes pages par LSim (`LSIM_SCREEN_ONLY`, `LSIM_DUMP`) et produit un rapport des écarts
   et des planches iPhone | LSim | différence.

### Ajustement automatique

Les valeurs mesurables vivent dans un **profil de design** JSON
(`Sources/LSimUI/Profiles/iOS-27.2.json`) : approche du texte par corps et par graisse, gabarits
de boutons par taille, couleurs, matière du verre, et aussi les *comportements* (couleur du libellé,
sensibilité à `controlSize`, type de remplissage). LSim le lit au démarrage ; `LSIM_PROFILE`
permet d'en essayer une variante sans recompiler.

Une seule commande fait tout :

```bash
python3 -I tools/calibration/calibrate.py
```

compile et installe le catalogue (xtool), attend que l'on touche l'icône sur l'iPhone, reçoit les
mesures, puis `fit.py` ajuste le profil (lecture directe des couches, choix des comportements par
recherche, marges et approche par correction des écarts, verre par recherche sur les pixels),
recompile LSim, enregistre les références dans `Tests/Calibration/` et lance `check.py`
(non-régression : échoue si un repère s'éloigne de plus de 0,5 pt de son résidu accepté).
Les écarts qu'aucun réglage n'explique sont listés comme anomalies dans `ajustement.md` : ce sont
eux, et eux seuls, qui demandent du code.

Les composants non encore passés au profil gardent des tables en code (`ListMetrics`,
`NavigationMetrics`), par génération de design (`DesignStyle` : Liquid Glass ou compatibilité).

Pièges connus : les captures d'iPhone sont en Display P3 (convertir avant de comparer) ;
`lld` inscrit la version minimale comme version du SDK (forcer `-platform_version`), sinon iOS
affiche l'app en mode compatibilité ; `xtool launch` ne fonctionne pas sur iOS 27 (lancer l'app
à la main).

## Lancer un projet : `lcode run`

```bash
swift build --product lcode
.build/debug/lcode run <projet xtool>            # simulateur LSim
.build/debug/lcode run <projet xtool> --device   # iPhone branché, via xtool
```

`LCodeKit` lit le projet (`swift package dump-package`), puis génère `<projet>/.lcode/simulateur/` :
un paquet dont les cibles sont des **liens** vers les sources du projet, compilées pour Linux contre
le module `SwiftUI` de LCode (LSimUI + LSimHost). Modifier le projet modifie donc le simulateur.
Limites actuelles : paquets externes et ressources non pris en charge (signalés au lancement).

### Couverture de l'API — sonde

`Examples/iOS/Sonde` est une app écrite « comme un développeur ordinaire » ; la relancer avec
`lcode run Examples/iOS/Sonde` vérifie la couverture de LSimUI. Depuis le 16/11/2026 elle compile et
s'affiche entièrement : `Image`/SF Symbols, `Label`, `TextField` (saisie au clavier), `Toggle`,
`Slider`, `Stepper`, `Picker` (menu et segmenté), `DatePicker`, `ProgressView`, `Form`,
`TabView`/`Tab`/`.tabItem`, `.sheet`, `.alert`, `.toolbar`, `@Bindable`, `@AppStorage`,
`.environment(objet)`, `GeometryReader`, `LazyVGrid`, `ScrollView(.horizontal)`, `Link`, `.task`.

Approximations connues (à calibrer ou à compléter) : animations (`withAnimation` s'applique sans
transition), menu de `Picker` (toucher = option suivante), `AsyncImage` sans téléchargement,
`.swipeActions`/`.searchable`/`.refreshable` acceptés sans effet, gabarits iOS 26 des nouveaux
contrôles estimés et non encore mesurés par le banc.

### Prochain chantier : Liquid Glass et animations

Vrai matériau de verre (réfraction/lentille de l'arrière-plan, reflets spéculaires), comportements
des barres (rétraction de la barre d'onglets au défilement, transitions de navigation), et
calibration des animations image par image (positions des couches Core Animation à chaque image).

## Limites assumées

- UIKit, frameworks matériels et fermés (ARKit, caméra, HealthKit…) : bouchons.
- Le simulateur valide l'UI et la logique, pas les performances réelles.
- Les tests finaux se font sur un vrai appareil via xtool.

## Feuille de route

1. **POC simulateur** : `VStack`, `HStack`, `Text`, `Button`, `Spacer`,
   `padding`, `@State`, dans une fenêtre iPhone. ← *en cours*
2. Navigation, List, modifiers courants, couleurs système, mode sombre.
3. Génération automatique du build simulateur depuis un projet xtool.
4. Shell de l'IDE : navigateur de fichiers, éditeur (GtkSourceView) + sourcekit-lsp,
   console de build, bouton Run (simulateur / appareil via xtool).
5. Profils iPad, Mac, Apple TV.
