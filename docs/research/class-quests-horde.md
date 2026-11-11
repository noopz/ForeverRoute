# Horde class quests, side trips and must-do chains on Forever (2026-11-10)

The research behind `tools/reviewed-horde.json`, the Horde version of `tools/reviewed-alliance.json`. Same format:
`special[]` side trips (filtered by `class` and `races` in `tools/make-character.js`), `mustDo[]`, `bonusQuests`,
`bonusNotes`. The Alliance file has no `optional` field. A trip that is not built into the path has no `inPath` and its
`why` says "Not built into the path: <reason>", as with Verigan's Fist and the Whirlwind weapon. This file does the same.

## How it was checked

- **Local QuestieDB** (`qdb/db.json`, now built from QuestieDB 1.0.14 Forever data). This gave the quest ids, givers,
  hand-ins, objectives, race and class masks, prerequisites and the NPC and object spawns behind every coordinate.
  - The file was first built on 1.0.13 and re-checked on 1.0.14 by comparing `qdb/db.old.json` with `qdb/db.json`.
  - 1.0.14 split Zephras Isle by faction. 94003 (Skybreaker Bulwark), 94006 (Great Ursera Spirit) and 98404 (relics
    for the Windborne Cat Spirit) are now Alliance Skyborne only, so the Windshaper entries were redone (see below).
  - Small changes that affect nothing here: 97245 is now open to all Horde races; 1516 and 1519 lost their
    self-referencing prerequisite; 79361 and 79366 changed only in starter order and objective items.
  - Every other quest in the file, mustDo included, is unchanged on 1.0.14.
  - 1.0.14 also made 92514 "Welcome to Shen'dar Village" and 92595 "The Windshapers" (Zephras Isle) **tauren only**
    (races 32). No tauren can be on Zephras Isle, so for a Windshaper these quests, and 94411 "Meddlesome Mages" that
    needs 92595, drop out of the route. None of them is in this file, but it looks like a data error worth an override:
    they were Horde-wide in 1.0.13.
- **Wowhead Forever data (dataEnv 16).** Every quest id in the file was checked through Wowhead's tooltip service,
  `https://nether.wowhead.com/tooltip/quest/<id>?dataEnv=16`, the same call `tools/wowhead.js` makes. That covers the
  37 trips (35 after the 1.0.14 redo) and the 57 must-do quests. That was 208 distinct ids, and 202 after the redo,
  re-checked on 2026-11-10. Every id returned 200. Each name matched our data, and
  each objective text matched our quest text. A test id that does not exist returns 404, so a 200 means the quest is in
  Forever's data. All 178 NPCs that give, take or are targets of these quests were checked the same way through
  `/tooltip/npc/<id>?dataEnv=16`. All exist and all names match except one: Wowhead spells 5683 "Corma Villard" and our
  data spells it "Comar Villard". That NPC is only in the Undercity Succubus chain, which the file does not use.
  - In the entries below, **"Wowhead Forever: verified"** means every quest id in that entry passed this check. The
    URL given is the entry's first quest page. The tooltip proves the quest exists in Forever and its text is unchanged.
    It does **not** show rewards.
  - **Rewards** (what spell or item a quest gives) are marked verified only where a Wowhead /forever quest page was read
    and showed the reward. Otherwise they are marked "reward not verified on Wowhead Forever".
- **Class spellbook changes** (`https://www.wowhead.com/forever/changes/spellbook/<class>`) could not be read by this
  research. The pages build their list in the browser, and the bot check was not worked around. The coordinator later
  read them in a browser:
  - **Wowhead Forever: verified** that every spell these trips reward exists on Forever, except two:
    - **Summon Felsteed is removed.** Its trip (3631 > 4490) was dropped.
    - **Defensive Stance is NOT removed** (corrected 2026-11-10). The spellbook-changes page lists it as removed, but
      Wowhead Forever's own tooltip for spell 71 shows it with its threat bonus raised to 80%, Taunt (355) still
      requires it, and Blizzard's Forever development notes (2026-11-03) list the buff. The page's "removed" was a
      misleading entry: check a spell's tooltip (dataEnv 16) before believing a removal.
- warcraft.wiki.gg and Wowhead Classic were used for what a Classic quest teaches.

## Horde races and classes on Forever

| Race | Classes | New on Forever |
|---|---|---|
| Orc | warrior, hunter, rogue, shaman, warlock, mage | mage |
| Undead | warrior, rogue, priest, mage, warlock, paladin | paladin |
| Tauren | warrior, hunter, shaman, druid | none |
| Troll | warrior, hunter, rogue, priest, shaman, mage, warlock | warlock |
| Windshaper Skyborne (Horde) | warrior, hunter, rogue, druid, shaman | shaman instead of the Alliance Skyborne's mage |

So Horde **paladins exist on Forever, as undead only**. Sources:

- Blizzard's announcement (https://news.blizzard.com/en-us/article/24304075) names Orc Mages, Troll Warlocks and Undead
  Paladins as new, says Windshapers can be Shaman, and gives the class counts 6/6/4/7/5.
- Warcraft Tavern (https://www.warcrafttavern.com/forever/guides/race-class-combos/) lists Horde Skyborne as Druid,
  Hunter, Rogue, Shaman and Warrior.
- Zockify (https://www.zockify.com/forever/races/) gives the full Horde table above.
- Our own data agrees: undead-only paladin quests (98601 and on), troll warlock 98575 "Tainted Tablet", orc mage 98576
  "Glyphic Parchment", and Skyborne-Horde shaman quests 97243-97257.

**Horde Skyborne race.** Blizzard calls them the **Windshaper Skyborne**. In the quest data they are race bit 2^33
(`SKYBORNE_HORDE`, raceKeys id 96), the `skybornehorde` key of `RACE_BIT` in `tools/world.js`.

- **Start zone:** the same **Zephras Isle, area id 16593** as the Alliance Skyborne. 92598 "The Gift of Skysight"
  (Horde Skyborne only) and the Horde-mask Zephras chain 92579-93090 start there. On 1.0.14, 92514 and 92595 are
  masked tauren only; see above. Horde Skyborne shamans start at
  Windshaper Boro in Thendal Grove, Zephras Isle (92466).
- **Leaving the island:** they finish with 95349 "The Earthen Ring" at Alaana Stormwalker and Muln Earthfury,
  **Skywatcher Plateau, Mulgore (about 33.4, 22.6)**. Quest 98517 says "the skycutter transport that docks in Mulgore at
  Skywatcher Plateau, northwest of Thunder Bluff". From there, 95350 "Welcome to Azeroth" leads to Thrall in Orgrimmar
  and 98024 to the Crossroads.

**Code note, not changed here:** `make-character.js` has `ALLIANCE = new Set([... 'skyborne'])` and the Alliance file
uses `races: ["skyborne"]`. This file uses `skybornehorde`, the `RACE_BIT` key. The save's race must normalise to
`skybornehorde` for a Horde Skyborne, or it will be treated as Alliance.

## Entries

### Warlock
- **Voidwalker, orc and troll (1506 > 1501 > 1504).** Ophek in Razor Hill, then Gan'rul Bloodeye, then the Tablet of
  Verga at the Burning Blade Stash, Skull Rock, then bind the Voidwalker.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=1506). Reward not verified on Wowhead Forever.
  - Resolved 2026-11-10: troll warlocks get this Voidwalker (the player). Our data still had the Classic orc-only
    race mask on 1501 and 1504, so tools/forever-overrides.json now opens both to trolls (races 130 = orc + troll).
  - Wowhead Forever spellbook changes (warlock): Summon Voidwalker unchanged at 10; Succubus, Incubus and Felhunter
    unchanged; Inferno unchanged at 50; Summon Felsteed removed.
  - On 1.0.14, 1501 and 1504 carry races 130 (orc + troll) in `qdb/db.json`. The override is no longer needed for them,
    but it does no harm.
- **Voidwalker, undead (1478 > 1473 > 1471).** Ageron Kargal in Brill, then Carendin Halgar in the Undercity, then
  Egalin's Grimoire from Perrine's Chest in Tirisfal.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=1478). Reward not verified on Wowhead Forever.
- **Succubus + Incubus (1507 > 1508 > 1509 > 1510 > 1511 > 1515 > 1512 > 1513, plus 65601 > 65610 > 65604).**
  - The Orgrimmar route, in the order the data's prerequisites give: Cazul, Zankaja, Gazrog (Crossroads), Ken'zigla
    (Malaka'jin, Stonetalon), Grunt Logmar (Camp Taurajo), Grunt Dogran (Barrens), then Gan'rul. The Incubus goes from
    Magar to the Withered Scarf at Fallen Sky Lake, Ashenvale (Shadethicket mobs).
  - The Undercity route (1472 > 1476 > 1474 and 65593 > 65597) is exclusive with this one. It was not used because its
    hearts come from Dalin Forgewright (Silverpine), Comar Villard (Wetlands, an Alliance zone), Avelina Lilly
    (Silverpine) and Isaac Pearson (Barrens).
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=1507). Reward not verified on Wowhead Forever.
- **Felhunter (2996 > 1801 > 1803 > 1805 > 1795).** Gan'rul sends you to Strahad Farsan (Ratchet), then Jorah Annison
  (Undercity), then the Moldy Tome (Hillsbrad coast, 27.8, 72.8), the Damaged Chest (Thousand Needles, 43.4, 32.7) and
  three Rods of Channeling from Dragonmaw in the Wetlands.
  - Like the Alliance entry, it has no `inPath`, because of the Wetlands step.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=2996). Reward not verified on Wowhead Forever.
- **Summon Felsteed (3631 > 4490): dropped.** Our user reports the spell is removed on Forever. The quest tooltips
  still exist, but the spellbook page could not be read here.
- **Infernal, 55 (7601 > 7602 > 7603).** Same chain as the Alliance entry, open to any race, with Horde flight points
  in the travel text.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=7601). Reward (Inferno) not verified on Wowhead
    Forever.
- Not included: 4737/4739 and 4967/4969 (Menara Voidrender, the Orb of Orahil), the same choice as the Alliance file.

### Hunter
- **Orc and troll (6062 > 6083 > 6082 > 6081).** Thotar in Razor Hill: tame a Dire Mottled Boar, a Surf Crawler and an
  Armored Scorpid, then Ormak Grimshot in Orgrimmar. The quest mask is orc+troll.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=6062). Reward not verified on Wowhead Forever.
- **Tauren (6061 > 6087 > 6088 > 6089).** Yaw Sharpmane in Bloodhoof: tame an Adult Plainstrider, a Prairie Stalker and
  a Swoop, then Holt Thunderhorn in Thunder Bluff.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=6061). Reward not verified on Wowhead Forever.
- **Windshaper (94007 > 94978 > 94979 > 94013 > 94050).** The shared Zephras Isle chain. It is still masked for both
  Skyborne on 1.0.14 (12884901888), so Windshaper hunters do have a level-10 class quest.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=94007). Reward not verified on Wowhead Forever.
- The "Hunter's Path" breadcrumbs (6065-6070) are left out, as on the Alliance side.

### Druid (tauren and Horde Skyborne)
- **Bear Form, tauren (5928 > 5922 > 5930 > 5932 > 6002).** Gennia Runetotem (Bloodhoof), Turak Runetotem (Thunder
  Bluff), the Great Bear Spirit in Moonglade, then Lunaclaw at the Moonkin Stone, Barrens (42, 61).
  - 5926 and 5927 are the same breadcrumb from Thunder Bluff and Orgrimmar. They are exclusive with 5928.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=5928). Reward not verified on Wowhead Forever.
- **Cure Poison, tauren (6126 > 6127 > 6128 > 6129 > 6130).** Dreadmist Peak, Tonga Runetotem at the Crossroads, then
  the Sickly Gazelles.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=6126). Reward not verified on Wowhead Forever.
- **Aquatic Form, tauren (27 > 28 > 30 > 31).**
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=27). Reward not verified on Wowhead Forever.
- **Cat Form, tauren (98340 > 98405 > 98342 > 98739 > 98362), new on Forever.** Wowhead /forever quest 98362 teaches
  **Cat Form (spell 768)**. Its series page gives the order: Great Cat Spirit, then the Windborne or plain Great Cat
  Spirit, then the relics from the Stormrage Barrow Dens, then Blessings, then To Thunder Bluff.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=98362). Reward verified on that page.
  - **The Alliance file has no Cat Form trip.** The night elf/Skyborne counterparts are 98393 ... 98397 "To Darnassus".
- **Windshaper Bear Form: entry removed on 1.0.14. Gap, not resolved.**
  - 94638 "Strength and Mercy" teaches Bear Form (spell 5487, Wowhead /forever quest 94638) and is masked for both
    Skyborne. But its only prerequisite, 94006 "The Great Ursera Spirit", is Alliance Skyborne only on 1.0.14, so by our
    data a Windshaper can never take it.
  - No other Windshaper or Horde Bear Form quest is in the data. The tauren chain 5926-6002 is tauren only.
  - Wowhead /forever 94913's completion text ("I see that you have already mastered the form of the Bear") suggests
    Windshapers learn Bear Form before Moonglade, presumably on Zephras Isle. Possibly a Horde counterpart of 94006 is
    missing from the data.
  - Not verified on Wowhead Forever: its quest pages show no side. Check in game.
- **Windshaper Teleport: Moonglade (94911 > 94913).** Masked Windshaper only on 1.0.14 (races 8589934592). Muln
  Earthfury (Skywatcher Plateau, Mulgore) sends you to Turak, then to Moonglade.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=94911).
- **Windshaper Cat Form (98340 > 98341 > 98738 > 98362).** Uses the Avatar of Saeyleenan, the Windborne Cat Spirit.
  - 98340 and 98362 are tauren + Windshaper; 98341 and 98738 are both-Skyborne.
  - **The relic step has no Windshaper version on 1.0.14.** 98404 is Alliance Skyborne only and 98342 is tauren only.
    The entry leaves it out and says so in its `why`. Expect the game to hand one of them out.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=98340). Cat Form reward verified on quest 98362.
- **Gap, not resolved:** our data gives the Horde Skyborne druid **no Cure Poison or Aquatic Form quest**. 6126-6130 and
  27-31 are tauren-only. For the Alliance Skyborne, 6121 and 272 carry the Skyborne bit. Unverified on Wowhead Forever.

### Rogue
- **Poisons, 20 (2460 > 2458 > 2478 > 2479 > 2480).** Shenthul (Orgrimmar), then Taskmaster Fizzule at the Venture Co.
  tower in the north Barrens, then Gallywix's head and the Cache of Zanzil's Altered Mixture, then Serge Hinott in Tarren
  Mill. In Classic this chain teaches Poisons.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=2460). Reward not verified on Wowhead Forever.
- Not included:
  - The level-10 race chains (1963/1858 Shattered Hand for orc and troll; 1885-1978 Deathstalkers for undead) and
    2378-2381 (Wrenix): item rewards only.
  - Forever 96784 "Master of Disguise": no giver in our### Warrior
- **Defensive Stance stays on Forever, buffed:** threat bonus 30% -> 80% (Wowhead Forever spell 71, dataEnv 16;
  Blizzard's Forever development notes, 2026-11-03, https://us.forums.blizzard.com/en/wow/t/wow-forever-beta-development-notes/2360696).
  Taunt still requires it. The level-10 quests below teach Defensive Stance, Taunt and Sunder Armor, as in Classic
  (warcraft.wiki.gg, Warrior abilities (Forever)); the entries say so again.
- **Path of Defense, orc/troll/tauren/Windshaper (1505 > 1498).** Uzzek at Far Watch Post wants 5 Singed Scales.
  - Wowhead Classic quest 1498 casts "Path of Defense".
  - 1505 and 1498 are masked for all Horde races including Windshaper. Windshapers were added to this entry on 1.0.14
    (see below).
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=1505). Reward on Forever not verified.
- **Ulag the Cleaver, undead (1818 > 1819).** Deathguard Dillinger in Brill: kill Ulag the Cleaver. It is exclusive
  with 1498.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=1818). Reward on Forever not verified.
- **Windshaper warrior: no Zephras Isle class quest on 1.0.14.** 94003 "The Skybreaker Bulwark" is now Alliance Skyborne
  only, so its Windshaper entry was removed. Their level-10 quest is Path of Defense, above.
- **Berserker Stance and the Whirlwind weapon (1718 > 1719 > 1791 > 1714 > 1712 > 1713 > 1792).** The same ids as the
  Alliance entry, open to any race. Not built into the path: the Cyclonian is an elite, and Essence of the Exile has no
  source in our data.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=1718). Reward not verified on Wowhead Forever.
- Not included: 1823-1848 (Ruga Ragetotem's trial and the Brutal armor set), which give items only.

### Shaman
- **Earth.**
  - Orc/troll 1516 > 1517 > 1518 (Canaga Earthcaller): Wowhead Forever verified
    (https://www.wowhead.com/forever/quest=1516).
  - Tauren 1519 > 1520 > 1521 (Seer Ravenfeather): Wowhead Forever verified
    (https://www.wowhead.com/forever/quest=1519).
  - Horde Skyborne 92466 > 92467 > 92468 (Windshaper Boro, Zephras Isle; Forever-new, exclusive with 1516/1519):
    Wowhead Forever verified (https://www.wowhead.com/forever/quest=92466).
  - The Earth Sapta replacement quests 1462 and 1463 are left out.
  - Rewards not verified on Wowhead Forever.
- **Fire.**
  - Orc/troll 2983 (Swart, Razor Hill) > 1524 > 1525 > 1526 > 1527: Wowhead Forever verified
    (https://www.wowhead.com/forever/quest=2983).
  - Tauren 2984 (Narm Skychaser) with the same chain: Wowhead Forever verified
    (https://www.wowhead.com/forever/quest=2984).
  - Windshaper 97243 > 97244 > 97245 > 97257 on Zephras Isle (Forever-new): Wowhead Forever verified
    (https://www.wowhead.com/forever/quest=97243).
    - On 1.0.14, 97243, 97244 and 97257 are Windshaper only; 97245 is open to all Horde races. Either way a Windshaper
      can take every step.
    - 98517 "Call of Fire" (Swart, Razor Hill; Windshaper only) sends a Windshaper who left the island at 10 back to
      Sessaria. It is left out of the entry.
  - Rewards not verified on Wowhead Forever.
- **Water (1530 > 1535 > 1536 > 1534 > 220 > 63 > 100 > 96).** Islen Waterseer, then Brine, then the waterskins (Brine's
  watering hole, the Tarren Mill well, the Ruins of Stardust), then the Corrupt Manifestation of Water at the Brazier of
  Everfount, Silverpine.
  - Unlike the Alliance version, every stop is safe for the Horde, so it is `inPath` (180 min).
  - 1530 has no prerequisite, so the breadcrumbs 1528, 1529, 2985 and 2986 are optional.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=1530). Reward not verified on Wowhead Forever.
- **Air, 30.** 1531 (orc/troll, Searn Firewarder) or 1532 (tauren/Skyborne, Xanis Flameweaver) leads to Prate
  Cloudseer. The two are exclusive. Wowhead /forever quest 1531 rewards the **Air Totem**.
  - On 1.0.14, 1532 is still masked for all Horde races, Windshaper included.
  - The new Windshaper-only 96136 "Call of Air" has no giver, no hand-in and no XP in the data, so it is not used.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=1531). Reward verified on that page.
- **The Tempest's Weapons (79360, 79364, 79361, 79366, 79442), Forever-new.** It rewards Lightning's Grasp, Tidebringer's
  Claw or Rage of the Storm, plus the Elementalist's Guard and the Rune of the Storm (Wowhead /forever quest 79442).
  - Not built into the path: Elemental Aid needs Charlga Razorflank in Razorfen Kraul. Our data has no prerequisites
    for the chain; the order used is Wowhead's series.
  - The Alliance file folds the Alliance version into its `inPath` Air trip.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=79442). Reward verified on that page.
- Not included: 79362 and 79363 (Grant's Shield and Silvia's Sword, orc/tauren/troll shaman, ending in Darkshire,
  Duskwood), which are Alliance-town quests with unclear value.

### Priest (troll, undead)
- **Troll (5654 > 5680).** Hex of Weakness at 10 (Tai'jin in Razor Hill, then Ur'kyo) and Shadowguard at 20 (Ur'kyo).
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=5654). Reward not verified on Wowhead Forever.
- **Undead (5658, 5679).** Touch of Weakness at 10 and Dark Sacrifice at 20, both from Aelthalyste in the Undercity.
  Wowhead Classic quest 5679 teaches Devouring Plague.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=5658). Reward not verified on Wowhead Forever.
- Each spell has several exclusive starters. The file uses the one nearest where the character is at that level.

### Mage
- **Orc and troll (1883 > 1884, Ju-Ju Heaps).** Wowhead Classic 1884 rewards the Ley Orb or Ley Staff, the same rewards
  as the Alliance Mirror Lake quest.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=1883). Reward not verified on Wowhead Forever.
- **Undead (1881 > 1882, The Balnir Farmstead).** Exclusive with 1884.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=1881). Reward not verified on Wowhead Forever.
- **Mask note:** our data masks 1881 and 1882 undead+troll, and 1884 orc+undead+troll. Orc mages are new; 1883 is open
  to every Horde race.
- Not included: the robe chains (1959-1962 Spellfire Robes, 1943-1946 Nether-lace), as on the Alliance side.

### Paladin (undead only)
- **Redemption (94427 > 94434 > 94435 > 94436 > 94438 > 94440 > 94441), Forever-new.** Danitha Morr (Bandarion Keep,
  Tirisfal) sends you to Tanis Alderwood (Undercity) with 10 Linen Cloth. The Symbol of Life resurrects Deathguard
  Falgan at Venomweb Vale; then the Scarlet Crusade Attack Plans.
  - The chain mirrors the Alliance Redemption chains. The Redemption reward itself is not verified on Wowhead Forever.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=94427).
- **The Moonsilver Blade (91858 ... 95140), Forever-new; the Horde counterpart of Verigan's Fist.**
  - Series from Wowhead /forever quest 95126: 91858 > 91859 > 91860 > 91861 > 91862 > 96204 > 95034 > 95036 > 95111 >
    95125 > 95126, with 95140 Old Fire-Eye after it and 95042 Seeking the Kor Gem alongside.
  - Not built into the path: Whitestone Oak Lumber drops only from Goblin Woodcarvers in The Deadmines, and the
    Purified Kor Gem comes from Blackfathom naga.
  - Wowhead Forever: verified (https://www.wowhead.com/forever/quest=95126). The Moonsilver Blade reward is verified
    on that page.
- **No Horde paladin mount quest** (the counterpart of 1661 Tome of Nobility) exists in our data. Unverified on Wowhead
  Forever whether undead paladins get a mount spell some other way.

### Cozy Sleeping Bag (any class, `bonusQuests`)
- Horde order: 79007 > 79192 > 79980 > 79974 > 79975 > 79976.
  - Our data: 79007 is Horde-only (Burned-Out Remains, Barrens 46.4, 73.9). 79008 is the Alliance start (Westfall).
  - Wowhead /forever (qdb/wowhead/79974.json) gives the series 79007, 79008, 79192, ...
  - warcraft.wiki.gg "...and that note you found (Horde)" says it starts south of Camp Taurajo, requires level 14,
    ends at the Westfall remains, and "the Horde visits the first two locations in reverse order".
- The route then passes Westfall and Loch Modan (both Alliance zones), Stonetalon, and Thoradin's Wall in Arathi.
- Wowhead Forever: verified (https://www.wowhead.com/forever/quest=79007).

## mustDo (57 quests)

All 57 ids are Wowhead Forever verified through the tooltip check (exist, names and text match). The Horde chains below
are the ones Classic Horde leveling guides (Joana's Horde guide, the Wowhead Classic Horde leveling guides) route
through in the 12-40 range. They were picked by the same rule as the Alliance list: chains, not one-off quests, and no
dungeons or elites.

- **The Barrens:**
  - Samophlange 894, 900, 901, 902
  - Ignition and The Escape 858, 863
  - Regthar Deathgate's centaur chain 850, 851, 852, 4021 (Counterattack!)
  - Centaur Bracers 855
  - Lost in Battle 4921
  - The Echeyakee, Angry Scytheclaws, Jorn Skyseer and Ishamuhale chain 881, 905, 3261, 882
- **Stonetalon:** Avenge My Village and Kill Grundig Darkcloud 6548, 6629; Gerenzo's Orders 1090, 1092.
- **Hillsbrad:**
  - Battle of Hillsbrad 527, 528, 529, 532, 539, 541, 550
  - Elixir of Agony 509, 513, 515, 517, 524
- **Ashenvale:** Torek's Assault 6544, Satyr Horns 6441, Warsong Supplies 6571.
- **Thousand Needles:** Free at Last 4904; Load Lightening and Goblin Sponsorship 1176, 1178, 1180, 1181, 1182, 1183
  (open to any race; also on the Alliance list).
- **Desolace:** Kodo Roundup 5561; The Kolkar of Desolace and Khan Dez'hepah 1362, 1365.
- **Dustwallow:** The Black Shield 1251, 1321, 1322, 1323; Stinky's Escape 1270.
  - 1276 is left out: it also needs Questioning Reethe (1273 and its prerequisites).
- **Forever-new:** these are included for their XP and because they form coherent chains, not because an expert guide
  names them.
  - Vrang Wildgore's chain, north Barrens: 95494, 95507, 95495, 95508, 95621. The order comes from Wowhead /forever
    quest 95621's series.
  - Scout Support and Valuable Vantages, Hillsbrad: 98094, 98095.

**Left out on purpose:**
- Starting-zone chains, because mustDo applies to every race.
- Silverpine's Arugal's Folly chain (421-424, 99), because it is undead-path only.
- The Test of Faith, Endurance, Strength and Lore chain (1149 and on). Rok'Alim the Pounder in Test of Strength is an
  elite, and Test of Lore 1160 needs Scarlet Monastery.
- Unending Torment (97288-97292). It starts from the Abominable Head dropped by "The Baron", an instance NPC (zone 16611).
- The Arathi Forever storyline (zone 16732: 95663, 95664, 95682, 95697, 98823). Our data lists 0 XP for it and has
  quests with no giver, so it was not reviewed.

## bonusQuests and bonusNotes

The Cozy Sleeping Bag chain above, with a note on 79007. No other Horde Forever bonus chain was found. "Bonus" here means
a lasting XP item, like the bag.
