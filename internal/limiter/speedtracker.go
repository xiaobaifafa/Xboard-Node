package limiter

import (
	"sync"
	"sync/atomic"

	"github.com/cedar2025/xboard-node/internal/model"
	"golang.org/x/time/rate"
)

const unlimitedBurst = int(^uint(0) >> 1)

// SpeedTracker maintains one shared rate.Limiter per user. Unlimited users
// also receive an infinite-rate limiter so Xray wraps their sessions from the
// start; changing a user from unlimited to limited then affects existing
// connections without requiring a reconnect.
type SpeedTracker struct {
	limiter *Limiter
	mu      sync.RWMutex
	buckets map[int]*rate.Limiter // userID → shared limiter, including unlimited users
	uuidMap map[string]int        // UUID → userID

	hasLimits    atomic.Bool
	limitedUsers int // protected by mu
	logFunc      SpeedTrackerLogCallback
}

// SpeedTrackerLogCallback is called when bucket updates occur.
type SpeedTrackerLogCallback func(msg string)

// NewSpeedTracker creates a bucket manager for per-user bandwidth throttling.
func NewSpeedTracker(l *Limiter) *SpeedTracker {
	return &SpeedTracker{
		limiter: l,
		buckets: make(map[int]*rate.Limiter),
		uuidMap: make(map[string]int),
	}
}

// SetLogCallback sets the logging callback.
func (t *SpeedTracker) SetLogCallback(f SpeedTrackerLogCallback) {
	t.logFunc = f
}

// UpdateBuckets updates each user's limiter in place. Existing Xray writers
// retain the same limiter pointer, so speed changes (including removing a
// limit) immediately affect already-established sessions.
func (t *SpeedTracker) UpdateBuckets() {
	currentUsers := make([]model.UserSpec, 0, 32)
	t.limiter.mu.RLock()
	for _, u := range t.limiter.users {
		currentUsers = append(currentUsers, u)
	}
	t.limiter.mu.RUnlock()

	t.mu.Lock()
	newUUIDMap := make(map[string]int, len(currentUsers))
	activeIDs := make(map[int]struct{}, len(currentUsers))
	limitedUsers := 0

	for _, user := range currentUsers {
		activeIDs[user.ID] = struct{}{}
		if user.UUID != "" {
			newUUIDMap[user.UUID] = user.ID
		}

		lim := t.buckets[user.ID]
		if lim == nil {
			// Install a limiter even for unlimited users. Xray attaches this
			// pointer to the session writer once; later updates are in-place.
			lim = rate.NewLimiter(rate.Inf, unlimitedBurst)
			t.buckets[user.ID] = lim
		}

		if user.SpeedLimit > 0 {
			bytesPerSec := int(user.SpeedLimit) * 1_000_000 / 8
			burst := bytesPerSec
			if burst < 64*1024 {
				burst = 64 * 1024
			}
			lim.SetLimit(rate.Limit(bytesPerSec))
			lim.SetBurst(burst)
			limitedUsers++
		} else {
			lim.SetLimit(rate.Inf)
			lim.SetBurst(unlimitedBurst)
		}
	}

	// Retire removed users' limiters. Existing writers may still hold these
	// pointers briefly, so make them unlimited before dropping the map entry.
	for id, lim := range t.buckets {
		if _, ok := activeIDs[id]; !ok {
			lim.SetLimit(rate.Inf)
			lim.SetBurst(unlimitedBurst)
			delete(t.buckets, id)
		}
	}

	t.uuidMap = newUUIDMap
	t.limitedUsers = limitedUsers
	t.hasLimits.Store(limitedUsers > 0)
	t.mu.Unlock()

	if t.logFunc != nil {
		t.logFunc("buckets updated")
	}
}

// GetLimiter returns the stable per-user limiter used by Xray. It returns nil
// only when the UUID is not part of the current user snapshot.
func (t *SpeedTracker) GetLimiter(user string) *rate.Limiter {
	t.mu.RLock()
	defer t.mu.RUnlock()

	uid, exists := t.uuidMap[user]
	if !exists {
		return nil
	}
	return t.buckets[uid]
}

// HasLimits reports whether any user currently has a positive speed limit.
func (t *SpeedTracker) HasLimits() bool {
	return t.hasLimits.Load()
}

// LimitedUserCount returns the number of users with active speed limits.
func (t *SpeedTracker) LimitedUserCount() int {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.limitedUsers
}
