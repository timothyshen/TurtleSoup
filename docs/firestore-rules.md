# Firestore Security Rules

Apply these rules in **Firebase Console → Firestore Database → Rules**.

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    // Users can only read/write their own data
    match /users/{uid}/{document=**} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }

    // Public puzzles: anyone can read; only the author can write
    match /publicPuzzles/{puzzleId} {
      allow read: if true;
      allow write: if request.auth != null
                   && request.resource.data.authorUID == request.auth.uid;
    }
  }
}
```

## Data Schema

```
/users/{uid}/
  gameRecords/{startedAt_epoch}/
    puzzleID      : String (UUID)
    puzzleTitle   : String
    startedAt     : Timestamp
    endedAt       : Timestamp
    isWon         : Bool
    questionCount : Int

  puzzles/{puzzleId}/
    id            : String (UUID)
    title         : String
    difficulty    : String ("简单" | "中等" | "困难")
    scenario      : String
    answer        : String
    hint          : String? (optional)
    author        : String
    playCount     : Int

/publicPuzzles/{puzzleId}/
  id            : String (UUID)
  title         : String
  difficulty    : String
  scenario      : String
  answer        : String
  hint          : String? (optional)
  author        : String
  playCount     : Int
  authorUID     : String (Firebase UID)
  publishedAt   : Timestamp (server timestamp)
```
