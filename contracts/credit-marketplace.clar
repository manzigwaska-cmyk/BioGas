;; title: credit-marketplace
;; version: 1.0
;; summary: Cooking fuel credit trading marketplace for biogas tokenization
;; description: Decentralized marketplace for buying, selling, and trading biogas cooking fuel credits

;; constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-not-authorized (err u201))
(define-constant err-invalid-order (err u202))
(define-constant err-insufficient-balance (err u203))
(define-constant err-order-not-found (err u204))
(define-constant err-invalid-price (err u205))
(define-constant err-order-expired (err u206))
(define-constant err-self-trade (err u207))
(define-constant err-order-fulfilled (err u208))
(define-constant err-invalid-amount (err u209))

;; Order types
(define-constant order-type-buy u1)
(define-constant order-type-sell u2)

;; Order status
(define-constant status-active u1)
(define-constant status-fulfilled u2)
(define-constant status-cancelled u3)
(define-constant status-expired u4)

;; Fee structure (basis points, 1 bp = 0.01%)
(define-constant trading-fee u250)      ;; 2.5% trading fee
(define-constant listing-fee u50)       ;; 0.5% listing fee
(define-constant premium-discount u200) ;; 2% discount for verified producers

;; data vars
(define-data-var order-nonce uint u0)
(define-data-var total-volume-traded uint u0)
(define-data-var total-trades-executed uint u0)
(define-data-var marketplace-fees-collected uint u0)
(define-data-var daily-trading-limit uint u10000) ;; Max credits per user per day
(define-data-var minimum-order-size uint u10)     ;; Minimum credits per order
(define-data-var maximum-order-validity uint u1440) ;; Max validity in blocks (~10 days)

;; data maps
(define-map trading-orders uint
  {
    creator: principal,
    order-type: uint,     ;; 1 = buy, 2 = sell
    credit-amount: uint,
    price-per-credit: uint, ;; in micro-STX
    total-value: uint,
    created-at: uint,
    expires-at: uint,
    status: uint,
    filled-amount: uint,
    counterpart: (optional principal),
    execution-date: (optional uint)
  }
)

(define-map user-balances principal
  {
    stx-balance: uint,
    credit-balance: uint,
    escrowed-stx: uint,
    escrowed-credits: uint,
    last-trade-date: uint,
    daily-trade-volume: uint
  }
)

(define-map trading-history uint
  {
    buy-order-id: uint,
    sell-order-id: uint,
    buyer: principal,
    seller: principal,
    credits-traded: uint,
    price-per-credit: uint,
    total-value: uint,
    trading-fee: uint,
    execution-timestamp: uint
  }
)

(define-map market-statistics uint
  {
    date: uint,
    total-orders-created: uint,
    total-orders-fulfilled: uint,
    average-price: uint,
    highest-price: uint,
    lowest-price: uint,
    total-volume: uint
  }
)

(define-map user-ratings principal
  {
    total-trades: uint,
    successful-trades: uint,
    rating-score: uint, ;; 1-100
    is-verified-trader: bool,
    reputation-level: uint ;; 1-5 stars
  }
)

(define-map price-alerts principal
  {
    target-price: uint,
    alert-type: uint, ;; 1 = price above, 2 = price below
    is-active: bool,
    created-at: uint
  }
)

;; public functions

;; Initialize user balance tracking
(define-public (initialize-user-balance)
  (let (
    (existing-balance (map-get? user-balances tx-sender))
  )
    (if (is-none existing-balance)
      (begin
        (map-set user-balances tx-sender {
          stx-balance: u0,
          credit-balance: u0,
          escrowed-stx: u0,
          escrowed-credits: u0,
          last-trade-date: u0,
          daily-trade-volume: u0
        })
        (ok true)
      )
      (ok false)
    )
  )
)

;; Create buy order
(define-public (create-buy-order
  (credit-amount uint)
  (price-per-credit uint)
  (validity-blocks uint)
)
  (let (
    (order-id (+ (var-get order-nonce) u1))
    (total-cost (+ (* credit-amount price-per-credit) (calculate-trading-fee (* credit-amount price-per-credit))))
    (user-balance (unwrap! (map-get? user-balances tx-sender) err-insufficient-balance))
  )
    (asserts! (>= credit-amount (var-get minimum-order-size)) err-invalid-amount)
    (asserts! (> price-per-credit u0) err-invalid-price)
    (asserts! (<= validity-blocks (var-get maximum-order-validity)) err-invalid-amount)
    (asserts! (>= (get stx-balance user-balance) total-cost) err-insufficient-balance)
    
    ;; Create the order
    (map-set trading-orders order-id {
      creator: tx-sender,
      order-type: order-type-buy,
      credit-amount: credit-amount,
      price-per-credit: price-per-credit,
      total-value: (* credit-amount price-per-credit),
      created-at: stacks-block-height,
      expires-at: (+ stacks-block-height validity-blocks),
      status: status-active,
      filled-amount: u0,
      counterpart: none,
      execution-date: none
    })
    
    ;; Escrow STX for the purchase
    (map-set user-balances tx-sender (merge user-balance {
      stx-balance: (- (get stx-balance user-balance) total-cost),
      escrowed-stx: (+ (get escrowed-stx user-balance) total-cost)
    }))
    
    (var-set order-nonce order-id)
    (ok order-id)
  )
)

;; Create sell order
(define-public (create-sell-order
  (credit-amount uint)
  (price-per-credit uint)
  (validity-blocks uint)
)
  (let (
    (order-id (+ (var-get order-nonce) u1))
    (user-balance (unwrap! (map-get? user-balances tx-sender) err-insufficient-balance))
  )
    (asserts! (>= credit-amount (var-get minimum-order-size)) err-invalid-amount)
    (asserts! (> price-per-credit u0) err-invalid-price)
    (asserts! (<= validity-blocks (var-get maximum-order-validity)) err-invalid-amount)
    (asserts! (>= (get credit-balance user-balance) credit-amount) err-insufficient-balance)
    
    ;; Create the order
    (map-set trading-orders order-id {
      creator: tx-sender,
      order-type: order-type-sell,
      credit-amount: credit-amount,
      price-per-credit: price-per-credit,
      total-value: (* credit-amount price-per-credit),
      created-at: stacks-block-height,
      expires-at: (+ stacks-block-height validity-blocks),
      status: status-active,
      filled-amount: u0,
      counterpart: none,
      execution-date: none
    })
    
    ;; Escrow credits for the sale
    (map-set user-balances tx-sender (merge user-balance {
      credit-balance: (- (get credit-balance user-balance) credit-amount),
      escrowed-credits: (+ (get escrowed-credits user-balance) credit-amount)
    }))
    
    (var-set order-nonce order-id)
    (ok order-id)
  )
)

;; Execute trade (fulfill order)
(define-public (execute-trade
  (order-id uint)
  (credits-to-buy uint)
)
  (let (
    (order-info (unwrap! (map-get? trading-orders order-id) err-order-not-found))
    (seller (get creator order-info))
    (buyer-balance (unwrap! (map-get? user-balances tx-sender) err-insufficient-balance))
    (seller-balance (unwrap! (map-get? user-balances seller) err-insufficient-balance))
    (trade-value (* credits-to-buy (get price-per-credit order-info)))
    (trading-fee-amount (calculate-trading-fee trade-value))
    (total-cost (+ trade-value trading-fee-amount))
    (trade-id (+ (var-get total-trades-executed) u1))
  )
    (asserts! (not (is-eq tx-sender seller)) err-self-trade)
    (asserts! (is-eq (get status order-info) status-active) err-order-fulfilled)
    (asserts! (< stacks-block-height (get expires-at order-info)) err-order-expired)
    (asserts! (<= credits-to-buy (- (get credit-amount order-info) (get filled-amount order-info))) err-invalid-amount)
    
    (if (is-eq (get order-type order-info) order-type-sell)
      ;; Buying from a sell order
      (begin
        (asserts! (>= (get stx-balance buyer-balance) total-cost) err-insufficient-balance)
        
        ;; Transfer STX from buyer to seller
        (map-set user-balances tx-sender (merge buyer-balance {
          stx-balance: (- (get stx-balance buyer-balance) total-cost),
          credit-balance: (+ (get credit-balance buyer-balance) credits-to-buy)
        }))
        
        (map-set user-balances seller (merge seller-balance {
          stx-balance: (+ (get stx-balance seller-balance) trade-value),
          escrowed-credits: (- (get escrowed-credits seller-balance) credits-to-buy)
        }))
      )
      ;; Selling to a buy order
      (begin
        (asserts! (>= (get credit-balance buyer-balance) credits-to-buy) err-insufficient-balance)
        
        ;; Transfer credits from seller to buyer
        (map-set user-balances tx-sender (merge buyer-balance {
          credit-balance: (- (get credit-balance buyer-balance) credits-to-buy),
          stx-balance: (+ (get stx-balance buyer-balance) trade-value)
        }))
        
        (map-set user-balances seller (merge seller-balance {
          escrowed-stx: (- (get escrowed-stx seller-balance) total-cost),
          credit-balance: (+ (get credit-balance seller-balance) credits-to-buy)
        }))
      )
    )
    
    ;; Update order status
    (let (
      (new-filled-amount (+ (get filled-amount order-info) credits-to-buy))
      (order-complete (is-eq new-filled-amount (get credit-amount order-info)))
    )
      (map-set trading-orders order-id (merge order-info {
        filled-amount: new-filled-amount,
        status: (if order-complete status-fulfilled status-active),
        counterpart: (some tx-sender),
        execution-date: (some stacks-block-height)
      }))
    )
    
    ;; Record trade history
    (map-set trading-history trade-id {
      buy-order-id: (if (is-eq (get order-type order-info) order-type-buy) order-id u0),
      sell-order-id: (if (is-eq (get order-type order-info) order-type-sell) order-id u0),
      buyer: (if (is-eq (get order-type order-info) order-type-sell) tx-sender seller),
      seller: (if (is-eq (get order-type order-info) order-type-sell) seller tx-sender),
      credits-traded: credits-to-buy,
      price-per-credit: (get price-per-credit order-info),
      total-value: trade-value,
      trading-fee: trading-fee-amount,
      execution-timestamp: stacks-block-height
    })
    
    ;; Update global statistics
    (var-set total-trades-executed trade-id)
    (var-set total-volume-traded (+ (var-get total-volume-traded) credits-to-buy))
    (var-set marketplace-fees-collected (+ (var-get marketplace-fees-collected) trading-fee-amount))
    
    (ok trade-id)
  )
)

;; Cancel order
(define-public (cancel-order (order-id uint))
  (let (
    (order-info (unwrap! (map-get? trading-orders order-id) err-order-not-found))
    (user-balance (unwrap! (map-get? user-balances tx-sender) err-insufficient-balance))
  )
    (asserts! (is-eq tx-sender (get creator order-info)) err-not-authorized)
    (asserts! (is-eq (get status order-info) status-active) err-order-fulfilled)
    
    ;; Return escrowed funds
    (if (is-eq (get order-type order-info) order-type-buy)
      ;; Return escrowed STX for buy order
      (map-set user-balances tx-sender (merge user-balance {
        stx-balance: (+ (get stx-balance user-balance) (- (get total-value order-info) (* (get filled-amount order-info) (get price-per-credit order-info)))),
        escrowed-stx: (- (get escrowed-stx user-balance) (- (get total-value order-info) (* (get filled-amount order-info) (get price-per-credit order-info))))
      }))
      ;; Return escrowed credits for sell order
      (map-set user-balances tx-sender (merge user-balance {
        credit-balance: (+ (get credit-balance user-balance) (- (get credit-amount order-info) (get filled-amount order-info))),
        escrowed-credits: (- (get escrowed-credits user-balance) (- (get credit-amount order-info) (get filled-amount order-info)))
      }))
    )
    
    ;; Update order status
    (map-set trading-orders order-id (merge order-info {
      status: status-cancelled
    }))
    
    (ok true)
  )
)

;; Update trading limits (admin function)
(define-public (update-trading-limits
  (daily-limit uint)
  (min-order uint)
  (max-validity uint)
)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set daily-trading-limit daily-limit)
    (var-set minimum-order-size min-order)
    (var-set maximum-order-validity max-validity)
    (ok true)
  )
)

;; Deposit STX to trading balance
(define-public (deposit-stx (amount uint))
  (let (
    (user-balance (unwrap! (map-get? user-balances tx-sender) err-insufficient-balance))
  )
    (asserts! (> amount u0) err-invalid-amount)
    
    ;; Transfer STX to contract (simplified - in real implementation would use stx-transfer?)
    (map-set user-balances tx-sender (merge user-balance {
      stx-balance: (+ (get stx-balance user-balance) amount)
    }))
    
    (ok amount)
  )
)

;; read only functions

(define-read-only (get-order-info (order-id uint))
  (map-get? trading-orders order-id)
)

(define-read-only (get-user-balance (user principal))
  (map-get? user-balances user)
)

(define-read-only (get-trade-history (trade-id uint))
  (map-get? trading-history trade-id)
)

(define-read-only (get-market-stats)
  {
    total-volume-traded: (var-get total-volume-traded),
    total-trades-executed: (var-get total-trades-executed),
    marketplace-fees-collected: (var-get marketplace-fees-collected),
    active-orders: (var-get order-nonce)
  }
)

(define-read-only (calculate-order-cost (credits uint) (price-per-credit uint))
  (let (
    (base-cost (* credits price-per-credit))
    (trading-fee-amount (calculate-trading-fee base-cost))
  )
    {
      base-cost: base-cost,
      trading-fee: trading-fee-amount,
      total-cost: (+ base-cost trading-fee-amount)
    }
  )
)

(define-read-only (get-current-market-price)
  ;; Simplified price discovery - in real implementation would calculate from recent trades
  u1000000 ;; 1 STX per credit as example
)

(define-read-only (is-order-expired (order-id uint))
  (match (map-get? trading-orders order-id)
    order-info (>= stacks-block-height (get expires-at order-info))
    true
  )
)

;; private functions

(define-private (calculate-trading-fee (trade-value uint))
  (/ (* trade-value trading-fee) u10000)
)

(define-private (calculate-listing-fee (order-value uint))
  (/ (* order-value listing-fee) u10000)
)

(define-private (get-verified-status (trader principal))
  (match (map-get? user-ratings trader)
    rating-info (get is-verified-trader rating-info)
    false
  )
)

