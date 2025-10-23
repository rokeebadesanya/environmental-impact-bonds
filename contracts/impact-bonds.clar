;; Environmental Impact Bonds Contract
;; Issues bonds that automatically pay higher returns if environmental targets are met

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-invalid-amount (err u103))
(define-constant err-bond-not-active (err u104))
(define-constant err-already-exists (err u105))
(define-constant err-not-matured (err u106))
(define-constant err-already-redeemed (err u107))
(define-constant err-insufficient-funds (err u108))
(define-constant err-target-not-verified (err u109))

;; Data Variables
(define-data-var bond-nonce uint u0)
(define-data-var total-bonds-issued uint u0)
(define-data-var total-value-locked uint u0)

;; Bond status constants
(define-constant status-active u1)
(define-constant status-matured u2)
(define-constant status-redeemed u3)
(define-constant status-defaulted u4)

;; Data Maps
(define-map bonds
  { bond-id: uint }
  {
    issuer: principal,
    project-name: (string-ascii 100),
    face-value: uint,
    base-return-rate: uint,
    enhanced-return-rate: uint,
    environmental-target: uint,
    current-performance: uint,
    issue-block: uint,
    maturity-block: uint,
    status: uint,
    total-invested: uint,
    target-verified: bool,
    oracle: principal
  }
)

(define-map bond-holders
  { bond-id: uint, holder: principal }
  { amount: uint, redeemed: bool }
)

(define-map holder-bonds
  { holder: principal }
  { bond-ids: (list 100 uint) }
)

(define-map environmental-metrics
  { bond-id: uint }
  {
    metric-type: (string-ascii 50),
    baseline: uint,
    target: uint,
    current-value: uint,
    last-updated: uint,
    verification-count: uint
  }
)

(define-map oracle-permissions
  { oracle: principal }
  { authorized: bool, bonds-managed: (list 50 uint) }
)

;; Read-only functions
(define-read-only (get-bond (bond-id uint))
  (map-get? bonds { bond-id: bond-id })
)

(define-read-only (get-bond-holder-info (bond-id uint) (holder principal))
  (map-get? bond-holders { bond-id: bond-id, holder: holder })
)

(define-read-only (get-holder-bonds (holder principal))
  (map-get? holder-bonds { holder: holder })
)

(define-read-only (get-environmental-metrics (bond-id uint))
  (map-get? environmental-metrics { bond-id: bond-id })
)

(define-read-only (get-total-bonds-issued)
  (var-get total-bonds-issued)
)

(define-read-only (get-total-value-locked)
  (var-get total-value-locked)
)

(define-read-only (calculate-returns (bond-id uint) (investment uint))
  (let
    (
      (bond (unwrap! (get-bond bond-id) err-not-found))
      (target-met (>= (get current-performance bond) (get environmental-target bond)))
      (return-rate (if target-met 
                      (get enhanced-return-rate bond)
                      (get base-return-rate bond)))
      (returns (/ (* investment return-rate) u10000))
    )
    (ok { principal: investment, returns: returns, total: (+ investment returns) })
  )
)

(define-read-only (is-bond-matured (bond-id uint))
  (let
    (
      (bond (unwrap! (get-bond bond-id) err-not-found))
    )
    (ok (>= block-height (get maturity-block bond)))
  )
)

(define-read-only (get-bond-status (bond-id uint))
  (let
    (
      (bond (unwrap! (get-bond bond-id) err-not-found))
    )
    (ok (get status bond))
  )
)

;; Private functions
(define-private (add-bond-to-holder (bond-id uint) (holder principal))
  (let
    (
      (current-bonds (default-to { bond-ids: (list ) } (get-holder-bonds holder)))
      (updated-bonds (unwrap! (as-max-len? (append (get bond-ids current-bonds) bond-id) u100) err-invalid-amount))
    )
    (map-set holder-bonds
      { holder: holder }
      { bond-ids: updated-bonds }
    )
    (ok true)
  )
)

;; Public functions
(define-public (issue-bond 
  (project-name (string-ascii 100))
  (face-value uint)
  (base-return-rate uint)
  (enhanced-return-rate uint)
  (environmental-target uint)
  (maturity-blocks uint)
  (metric-type (string-ascii 50))
  (baseline uint)
  (oracle principal)
)
  (let
    (
      (bond-id (+ (var-get bond-nonce) u1))
      (maturity-block (+ block-height maturity-blocks))
    )
    (asserts! (> face-value u0) err-invalid-amount)
    (asserts! (> enhanced-return-rate base-return-rate) err-invalid-amount)
    (asserts! (> environmental-target u0) err-invalid-amount)
    
    (map-set bonds
      { bond-id: bond-id }
      {
        issuer: tx-sender,
        project-name: project-name,
        face-value: face-value,
        base-return-rate: base-return-rate,
        enhanced-return-rate: enhanced-return-rate,
        environmental-target: environmental-target,
        current-performance: u0,
        issue-block: block-height,
        maturity-block: maturity-block,
        status: status-active,
        total-invested: u0,
        target-verified: false,
        oracle: oracle
      }
    )
    
    (map-set environmental-metrics
      { bond-id: bond-id }
      {
        metric-type: metric-type,
        baseline: baseline,
        target: environmental-target,
        current-value: baseline,
        last-updated: block-height,
        verification-count: u0
      }
    )
    
    (var-set bond-nonce bond-id)
    (var-set total-bonds-issued (+ (var-get total-bonds-issued) u1))
    
    (ok bond-id)
  )
)

(define-public (invest-in-bond (bond-id uint) (amount uint))
  (let
    (
      (bond (unwrap! (get-bond bond-id) err-not-found))
      (existing-investment (default-to { amount: u0, redeemed: false } 
                           (get-bond-holder-info bond-id tx-sender)))
    )
    (asserts! (is-eq (get status bond) status-active) err-bond-not-active)
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (< block-height (get maturity-block bond)) err-not-matured)
    
    ;; Transfer investment amount
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update bond holder information
    (map-set bond-holders
      { bond-id: bond-id, holder: tx-sender }
      { 
        amount: (+ (get amount existing-investment) amount),
        redeemed: false
      }
    )
    
    ;; Update bond total invested
    (map-set bonds
      { bond-id: bond-id }
      (merge bond { total-invested: (+ (get total-invested bond) amount) })
    )
    
    ;; Add bond to holder's list
    (try! (add-bond-to-holder bond-id tx-sender))
    
    ;; Update total value locked
    (var-set total-value-locked (+ (var-get total-value-locked) amount))
    
    (ok true)
  )
)

(define-public (update-environmental-performance (bond-id uint) (new-performance uint))
  (let
    (
      (bond (unwrap! (get-bond bond-id) err-not-found))
      (metrics (unwrap! (get-environmental-metrics bond-id) err-not-found))
    )
    (asserts! (is-eq tx-sender (get oracle bond)) err-unauthorized)
    (asserts! (is-eq (get status bond) status-active) err-bond-not-active)
    
    ;; Update bond performance
    (map-set bonds
      { bond-id: bond-id }
      (merge bond { 
        current-performance: new-performance,
        target-verified: (>= new-performance (get environmental-target bond))
      })
    )
    
    ;; Update environmental metrics
    (map-set environmental-metrics
      { bond-id: bond-id }
      (merge metrics {
        current-value: new-performance,
        last-updated: block-height,
        verification-count: (+ (get verification-count metrics) u1)
      })
    )
    
    (ok true)
  )
)

(define-public (redeem-bond (bond-id uint))
  (let
    (
      (bond (unwrap! (get-bond bond-id) err-not-found))
      (holder-info (unwrap! (get-bond-holder-info bond-id tx-sender) err-not-found))
      (investment (get amount holder-info))
      (returns-calc (unwrap! (calculate-returns bond-id investment) err-invalid-amount))
      (payout (get total returns-calc))
    )
    (asserts! (>= block-height (get maturity-block bond)) err-not-matured)
    (asserts! (not (get redeemed holder-info)) err-already-redeemed)
    (asserts! (> investment u0) err-invalid-amount)
    
    ;; Mark as redeemed
    (map-set bond-holders
      { bond-id: bond-id, holder: tx-sender }
      (merge holder-info { redeemed: true })
    )
    
    ;; Transfer payout
    (try! (as-contract (stx-transfer? payout tx-sender tx-sender)))
    
    ;; Update bond status if first redemption
    (if (is-eq (get status bond) status-active)
      (map-set bonds
        { bond-id: bond-id }
        (merge bond { status: status-redeemed })
      )
      true
    )
    
    (ok payout)
  )
)

(define-public (authorize-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set oracle-permissions
      { oracle: oracle }
      { authorized: true, bonds-managed: (list ) }
    )
    (ok true)
  )
)

(define-public (revoke-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set oracle-permissions
      { oracle: oracle }
      { authorized: false, bonds-managed: (list ) }
    )
    (ok true)
  )
)

(define-public (mature-bond (bond-id uint))
  (let
    (
      (bond (unwrap! (get-bond bond-id) err-not-found))
    )
    (asserts! (>= block-height (get maturity-block bond)) err-not-matured)
    (asserts! (is-eq (get status bond) status-active) err-bond-not-active)
    
    (map-set bonds
      { bond-id: bond-id }
      (merge bond { status: status-matured })
    )
    
    (ok true)
  )
)


;; title: impact-bonds
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

