# Administration familiale

Site web statique pour gérer les informations administratives d'une famille élargie,
adossé à une base Supabase.

## Fonctionnalités

- Accès aux données protégé par mot de passe : **chaque requête de lecture/écriture**
  vers la base transporte le mot de passe, vérifié côté serveur (bcrypt) à chaque appel.
- Tableau principal de tous les membres, triés par jour de l'année de naissance
  (anniversaires) : prénom, nom, date de naissance, âge.
- Barre de recherche portant sur **tous les champs** d'un membre (adresse, dates,
  email…). Les relations ne déclenchent pas de résultat.
- Colonnes du tableau triables (clic sur l'en-tête, tri croissant/décroissant) ;
  tri par défaut : jour de l'année de naissance.
- Bouton d'export (Excel `.xlsx` ou Word `.doc`) avec choix des champs à inclure ;
  l'export respecte la recherche courante.
- Bouton « Arbre généalogique » : graphe SVG construit à partir des liens
  parent/enfant et des conjoints (clic sur une carte = ouverture de la fiche).
- Adresses cliquables vers une carte (geo: sur Android, Maps sur iOS, Google Maps
  sur ordinateur) et emails cliquables en `mailto:`.
- Bouton « Copier les emails » : liste de diffusion des membres affichés.
- Bandeau de vœux les jours d'anniversaire des membres vivants.
- Fiche détaillée par membre : nom, prénom, sexe, date de naissance, adresse, email,
  date de mariage (facultatif), date de décès (facultatif), relations.
- Les relations sont modélisées par des liens parent → enfant ; les pères/mères et
  enfants sont stockés, les frères et sœurs sont déduits automatiquement. Le conjoint
  est un lien symétrique, cohérencé automatiquement dans les deux sens.
- Le nom de la famille à administrer est configurable (table `app_settings`, lecture
  publique) et s'affiche en haut de la page, même avant connexion.
- Comptes utilisateurs avec deux rôles : `admin` (lecture + écriture + gestion des
  comptes) et `viewer` (lecture seule). Les écritures sont refusées côté serveur
  pour les non-admins, pas seulement cachées dans l'interface.

## Sécurité

- Les données ne sont accessibles **que** via les fonctions RPC (`get_members`,
  `upsert_member`, `set_parent`, …) : les tables sont protégées par RLS sans aucune
  policy, donc l'accès direct depuis le navigateur avec la clé anon est refusé.
- Les mots de passe sont stockés hachés avec bcrypt (`pgcrypto`), jamais en clair.
- Il ne peut jamais exister moins d'un compte administrateur actif.
- Limitation connue : pas de anti brute-force natif sur les appels RPC PostgREST ;
  utilisez des mots de passe longs et remplacez les mots de passe initiaux
  immédiatement.

## Mise en place

1. **Créer le projet Supabase**
   - Créez un projet sur [supabase.com](https://supabase.com).
   - Ouvrez le *SQL Editor* et exécutez l'intégralité de `supabase/schema.sql`.
   - Exécutez ensuite les migrations `supabase/migrations/02_family_name.sql`
     puis `03_add_spouse.sql` (le nom de famille par défaut « Ma Famille » se
     change dans la table `app_settings` : `update app_settings set value = '…'
     where key = 'family_name';`).

2. **Changer les mots de passe initiaux**
   Dans le SQL Editor :
   ```sql
   update app_users set password_hash = crypt('VOTRE_MOT_DE_PASSE_ADMIN', gen_salt('bf', 12)) where username = 'admin';
   update app_users set password_hash = crypt('VOTRE_MOT_DE_PASSE_FAMILLE', gen_salt('bf', 12)) where username = 'famille';
   ```

3. **Configurer le frontend**
   Dans le Dashboard Supabase (*Settings → API*), récupérez l'URL du projet et la
   clé `anon` et renseignez-les dans `js/config.js`. La clé `anon` est publique par
   conception : c'est la RLS qui protège les données, pas la clé.

4. **Héberger le site statique**
   - `index.html`, `styles.css` et `js/` peuvent être servis depuis n'importe quel
     hébergeur statique (GitHub Pages, Netlify, etc.).
   - Pour GitHub Pages : poussez le dépôt puis *Settings → Pages → Deploy from
     branch → main / (root)*.

## Créer des comptes supplémentaires

Connectez-vous sur le site avec le compte `admin`, ouvrez « Utilisateurs » :
vous pouvez y créer des comptes (lecture seule ou admin), changer un mot de passe,
désactiver ou supprimer un compte.

## Structure du projet

```
├── index.html              Page unique (connexion, tableau, fiches, comptes, export, arbre)
├── styles.css
├── js/
│   ├── config.js           URL et clé anon Supabase (à renseigner)
│   ├── app.js              Logique applicative
│   ├── utils.js            Utilitaires partagés (dates, âge, liens carte/email)
│   ├── export.js           Export xlsx / Word avec choix des champs
│   └── tree.js             Arbre généalogique SVG
└── supabase/
    ├── schema.sql          Schema de référence (à exécuter une fois à l'installation)
    └── migrations/         Modifications du schéma, un script numéroté par changement
```

## Évolution du schéma

`supabase/schema.sql` est le schéma de référence executé à l'installation.
Toute modification ultérieure se fait dans un script dédié
`supabase/migrations/NN_description.sql`, à executer dans le SQL Editor de
Supabase dans l'ordre des numéros.
