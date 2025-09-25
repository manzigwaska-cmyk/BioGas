;; title: biogas-production
;; version: 1.0
;; summary: Biogas production tracking and cooking fuel credit tokenization
;; description: Manages biogas production verification, credit issuance, and producer rewards

;; constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-authorized (err u101))
(define-constant err-invalid-producer (err u102))
(define-constant err-invalid-amount (err u103))
(define-constant err-insufficient-credits (err u104))
(define-constant err-production-exists (err u105))
(define-constant err-invalid-timestamp (err u106))
(define-constant err-producer-not-found (err u107))
(define-constant err-invalid-facility (err u108))

;; Production facility types
(define-constant facility-household u1)
(define-constant facility-community u2)
(define-constant facility-commercial u3)
(define-constant facility-industrial u4)

;; Credit conversion rates (credits per unit of biogas)
(define-constant household-rate u10)    ;; 10 credits per cubic meter
(define-constant community-rate u15)    ;; 15 credits per cubic meter
(define-constant commercial-rate u20)   ;; 20 credits per cubic meter
(define-constant industrial-rate u25)   ;; 25 credits per cubic meter

;; data vars
(define-data-var total-credits-issued uint u0)
(define-data-var total-production-volume uint u0)
(define-data-var verified-producers uint u0)
(define-data-var production-nonce uint u0)
(define-data-var minimum-production-threshold uint u100) ;; Minimum cubic meters for credit issuance
(define-data-var quality-bonus-multiplier uint u120) ;; 20% bonus for high-quality production

;; data maps
(define-map biogas-producers principal
  {
    facility-type: uint,
    registered-at: uint,
    total-production: uint,
    total-credits-earned: uint,
    is-verified: bool,
    reputation-score: uint,
    last-production-date: uint,
    location: (string-ascii 100)
  }
)

(define-map production-records uint
  {
    producer: principal,
    production-date: uint,
    volume-produced: uint, ;; in cubic meters
    quality-score: uint,   ;; 1-100 quality rating
    credits-issued: uint,
    verification-status: bool,
    verified-by: (optional principal),
    verification-date: (optional uint),
    feedstock-type: (string-ascii 50)
  }
)

(define-map cooking-fuel-credits principal uint)

(define-map production-statistics uint
  {
    total-daily-production: uint,
    active-producers: uint,
    average-quality-score: uint,
    credits-distributed: uint
  }
)

(define-map facility-certifications principal
  {
    certification-level: uint, ;; 1-5 stars
    certified-by: principal,
    certification-date: uint,
    expiry-date: uint,
    is-active: bool
  }
)

;; public functions

;; Register as biogas producer
(define-public (register-producer 
  (facility-type uint)
  (location (string-ascii 100))
)
  (let (
    (existing-producer (map-get? biogas-producers tx-sender))
  )
    (asserts! (is-none existing-producer) err-invalid-producer)
    (asserts! (and (>= facility-type facility-household) (<= facility-type facility-industrial)) err-invalid-facility)
    
    (map-set biogas-producers tx-sender {
      facility-type: facility-type,
      registered-at: stacks-block-height,
      total-production: u0,
      total-credits-earned: u0,
      is-verified: false,
      reputation-score: u50, ;; Starting reputation
      last-production-date: u0,
      location: location
    })
    
    (var-set verified-producers (+ (var-get verified-producers) u1))
    (ok true)
  )
)

;; Record biogas production
(define-public (record-production
  (volume-produced uint)
  (quality-score uint)
  (feedstock-type (string-ascii 50))
)
  (let (
    (producer-info (unwrap! (map-get? biogas-producers tx-sender) err-producer-not-found))
    (production-id (+ (var-get production-nonce) u1))
    (facility-type (get facility-type producer-info))
    (base-rate (get-conversion-rate facility-type))
    (quality-multiplier (if (>= quality-score u80) (var-get quality-bonus-multiplier) u100))
    (credits-to-issue (* (/ (* volume-produced base-rate quality-multiplier) u100) u1))
  )
    (asserts! (> volume-produced u0) err-invalid-amount)
    (asserts! (and (>= quality-score u1) (<= quality-score u100)) err-invalid-amount)
    (asserts! (>= volume-produced (var-get minimum-production-threshold)) err-invalid-amount)
    
    ;; Record production
    (map-set production-records production-id {
      producer: tx-sender,
      production-date: stacks-block-height,
      volume-produced: volume-produced,
      quality-score: quality-score,
      credits-issued: credits-to-issue,
      verification-status: false,
      verified-by: none,
      verification-date: none,
      feedstock-type: feedstock-type
    })
    
    ;; Update producer statistics
    (map-set biogas-producers tx-sender (merge producer-info {
      total-production: (+ (get total-production producer-info) volume-produced),
      total-credits-earned: (+ (get total-credits-earned producer-info) credits-to-issue),
      last-production-date: stacks-block-height
    }))
    
    ;; Issue credits to producer
    (let (
      (current-credits (default-to u0 (map-get? cooking-fuel-credits tx-sender)))
    )
      (map-set cooking-fuel-credits tx-sender (+ current-credits credits-to-issue))
    )
    
    ;; Update global statistics
    (var-set production-nonce production-id)
    (var-set total-production-volume (+ (var-get total-production-volume) volume-produced))
    (var-set total-credits-issued (+ (var-get total-credits-issued) credits-to-issue))
    
    (ok production-id)
  )
)

;; Verify production record (admin function)
(define-public (verify-production
  (production-id uint)
  (approved bool)
)
  (let (
    (production-record (unwrap! (map-get? production-records production-id) err-invalid-amount))
    (producer (get producer production-record))
    (producer-info (unwrap! (map-get? biogas-producers producer) err-producer-not-found))
  )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (not (get verification-status production-record)) err-production-exists)
    
    ;; Update production record
    (map-set production-records production-id (merge production-record {
      verification-status: approved,
      verified-by: (some tx-sender),
      verification-date: (some stacks-block-height)
    }))
    
    ;; If approved, mark producer as verified and boost reputation
    (if approved
      (begin
        (map-set biogas-producers producer (merge producer-info {
          is-verified: true,
          reputation-score: (if (> (+ (get reputation-score producer-info) u10) u100) u100 (+ (get reputation-score producer-info) u10))
        }))
        (ok true)
      )
      ;; If rejected, reduce credits for this production
      (let (
        (credits-to-remove (get credits-issued production-record))
        (current-credits (default-to u0 (map-get? cooking-fuel-credits producer)))
      )
        (if (>= current-credits credits-to-remove)
          (map-set cooking-fuel-credits producer (- current-credits credits-to-remove))
          (map-set cooking-fuel-credits producer u0)
        )
        (ok false)
      )
    )
  )
)

;; Transfer credits between accounts
(define-public (transfer-credits
  (recipient principal)
  (amount uint)
)
  (let (
    (sender-balance (default-to u0 (map-get? cooking-fuel-credits tx-sender)))
    (recipient-balance (default-to u0 (map-get? cooking-fuel-credits recipient)))
  )
    (asserts! (>= sender-balance amount) err-insufficient-credits)
    (asserts! (> amount u0) err-invalid-amount)
    
    (map-set cooking-fuel-credits tx-sender (- sender-balance amount))
    (map-set cooking-fuel-credits recipient (+ recipient-balance amount))
    
    (ok true)
  )
)

;; Certify facility (admin function)
(define-public (certify-facility
  (producer principal)
  (certification-level uint)
  (validity-period uint)
)
  (let (
    (producer-info (unwrap! (map-get? biogas-producers producer) err-producer-not-found))
  )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (and (>= certification-level u1) (<= certification-level u5)) err-invalid-amount)
    
    (map-set facility-certifications producer {
      certification-level: certification-level,
      certified-by: tx-sender,
      certification-date: stacks-block-height,
      expiry-date: (+ stacks-block-height validity-period),
      is-active: true
    })
    
    ;; Boost reputation based on certification level
    (map-set biogas-producers producer (merge producer-info {
      reputation-score: (if (> (+ (get reputation-score producer-info) (* certification-level u5)) u100) u100 (+ (get reputation-score producer-info) (* certification-level u5)))
    }))
    
    (ok true)
  )
)

;; Update production thresholds (admin function)
(define-public (update-threshold (new-threshold uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> new-threshold u0) err-invalid-amount)
    (var-set minimum-production-threshold new-threshold)
    (ok new-threshold)
  )
)

;; read only functions

(define-read-only (get-producer-info (producer principal))
  (map-get? biogas-producers producer)
)

(define-read-only (get-production-record (production-id uint))
  (map-get? production-records production-id)
)

(define-read-only (get-credit-balance (account principal))
  (default-to u0 (map-get? cooking-fuel-credits account))
)

(define-read-only (get-facility-certification (producer principal))
  (map-get? facility-certifications producer)
)

(define-read-only (get-global-stats)
  {
    total-credits-issued: (var-get total-credits-issued),
    total-production-volume: (var-get total-production-volume),
    verified-producers: (var-get verified-producers),
    minimum-threshold: (var-get minimum-production-threshold)
  }
)

(define-read-only (calculate-potential-credits (facility-type uint) (volume uint) (quality uint))
  (let (
    (base-rate (get-conversion-rate facility-type))
    (quality-multiplier (if (>= quality u80) (var-get quality-bonus-multiplier) u100))
  )
    (* (/ (* volume base-rate quality-multiplier) u100) u1)
  )
)

(define-read-only (is-producer-verified (producer principal))
  (match (map-get? biogas-producers producer)
    producer-info (get is-verified producer-info)
    false
  )
)

;; private functions

(define-private (get-conversion-rate (facility-type uint))
  (if (is-eq facility-type facility-household)
    household-rate
    (if (is-eq facility-type facility-community)
      community-rate
      (if (is-eq facility-type facility-commercial)
        commercial-rate
        industrial-rate
      )
    )
  )
)

(define-private (calculate-reputation-boost (quality-score uint))
  (if (>= quality-score u90)
    u10
    (if (>= quality-score u70)
      u5
      u2
    )
  )
)

