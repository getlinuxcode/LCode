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

Les mesures sont reportées dans des tables (`ButtonMetrics`, `ListMetrics`, `NavigationMetrics`),
par génération de design (`DesignStyle` : Liquid Glass ou compatibilité).

Pièges connus : les captures d'iPhone sont en Display P3 (convertir avant de comparer) ;
`lld` inscrit la version minimale comme version du SDK (forcer `-platform_version`), sinon iOS
affiche l'app en mode compatibilité ; `xtool launch` ne fonctionne pas sur iOS 27 (lancer l'app
à la main).

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
