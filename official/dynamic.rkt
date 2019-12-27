#lang racket/base

(provide go)

(require file/sha1
         json
         net/sendmail
         net/url
         racket/file
         racket/list
         racket/match
         racket/set
         racket/string
         version/utils
         web-server/dispatch
         web-server/http
         web-server/http/basic-auth
         web-server/servlet-env
         (prefix-in bcrypt- bcrypt)
         "../basic/main.rkt"
         "build-update.rkt"
         "common.rkt"
         "notify.rkt"
         "static.rkt"
         "update.rkt")

(module+ test
  (require rackunit))

(define (package-remove! pkg-name)
  (delete-file (build-path^ pkgs-path pkg-name)))

;; returns package in its registered case or #f if no such package
(define (package-exists-as pkg-name)
  ;; check for a case-insensitive match, which on a case-sensitive
  ;; filesystem helps avoid creating problems for a
  ;; case-insensitive filesystem
  (for/or ([p (in-list (directory-list pkgs-path))])
    (define name (path-element->string p))
    (and (string-ci=? name pkg-name)
         name)))

(define (hash-deep-merge ht more-ht)
  (for/fold ([ht ht])
      ([(k new-v) (in-hash more-ht)])
    (hash-update ht k
                 (λ (old-v)
                   (cond
                     [(not old-v)
                      new-v]
                     [(hash? old-v)
                      (hash-deep-merge old-v new-v)]
                     [else
                      new-v]))
                 #f)))
(module+ test
  (check-equal?
   (hash-deep-merge (hasheq 'source "http://aws" 'descript "DrRacket")
                    (hasheq 'source "http://github"))
   (hasheq 'source "http://github" 'descript "DrRacket")))

(define (curation-administrator? u)
  (member u '("jay.mccarthy@gmail.com"
              "mflatt@cs.utah.edu"
              "samth@ccs.neu.edu"
              "stamourv@racket-lang.org"
              "tonygarnockjones@gmail.com")))

;; This predicate means "Can `u` edit or delete arbitrary packages?"
;; For now, it's the same set of people as can curate packages, but we
;; can think about how we want to do this in future.
(define (superuser? u)
  (curation-administrator? u))

(define (api/upload req)
  (define req-data (read (open-input-bytes (or (request-post-data/raw req) #""))))
  (match-define (list email given-password pis) req-data)
  (define password-path (build-path^ users.new-path email))
  (define expected-password (file->bytes password-path))
  (define password-okay? (bcrypt-check expected-password given-password))
  (define curator? (curation-administrator? email))
  (cond
    [(not (and password-okay? curator?))
     (log! "api/upload! failed pass(~a) curator(~a) email was ~v"
           password-okay?
           curator?
           email)
     (response/sexpr #f)]
    [else
     (log! "receiving api/upload!")
     (cond
       [(for/or ([p (in-hash-keys pis)])
          (define old-p (package-exists-as p))
          (and (not (equal? p old-p))
               (begin
                 (log! "case mismatch for package name ~s" p)
                 #t)))
        (response/sexpr #f)]
       [else
        (for ([(p more-pi) (in-hash pis)])
          (log! "received api/upload for ~a" p)
          (define pi 
            (cond
              [(package-exists-as p)
               (package-info p)]
              [else
               #hash()]))
          (define new-pi (hash-deep-merge pi more-pi))
          (define updated-pi
            (hash-remove
             (let ([now (current-seconds)])
               (for/fold ([pi new-pi])
                         ([k (in-list '(last-edit last-checked last-updated))])
                 (hash-set pi k now)))
             'checksum))
          (log! "api/upload old ~v more ~v new ~v updated ~v"
                (hash-ref pi 'source #f)
                (hash-ref more-pi 'source #f)
                (hash-ref new-pi 'source #f)
                (hash-ref updated-pi 'source #f))
          (package-info-set! p updated-pi))
        (signal-update! (hash-keys pis))
        (response/sexpr #t)])]))

(define redirect-to-static
  (get-config redirect-to-static-proc
              (lambda (req)
                (redirect-to
                 (url->string
                  (struct-copy url (request-uri req)
                               [scheme (get-config redirect-to-static-scheme "http")]
                               [host (get-config redirect-to-static-host "pkgs.racket-lang.org")]
                               [port (get-config redirect-to-static-port 80)]))))))

(define (salty str)
  (sha1 (open-input-string str)))

(define current-user (make-parameter #f))
(define (ensure-authenticate req body-fun)
  (match (request->basic-credentials req)
    [(cons email passwd)
     (ensure-authenticate/email+passwd (bytes->string/utf-8 email)
                                       (bytes->string/utf-8 passwd)
                                       body-fun)]
    [_
     ;; TODO: things are structured awkwardly at the moment, but it'd
     ;; be nice to have this generate 401 Authentication Required with
     ;; a use of `make-basic-auth-header` to request credentials.
     "authentication-required"]))

(define (ensure-authenticate/email+passwd email passwd body-fun)
  (define passwd-path (build-path^ users.new-path email))
  (cond [(not (file-exists? passwd-path))
         "new-user"]
        [(not (bcrypt-check (file->bytes passwd-path) (string->bytes/utf-8 passwd)))
         "failed"]
        [else
         (parameterize ([current-user email]) (body-fun))]))

;; email-codes: (Hashtable String String)
;; Key: email address.
;; Value: code sent out in email and required for registration of a new password.
(define email-codes (make-hash))
;; TODO: Expire codes.

(define (generate-a-code! email)
  (define correct-email-code
    (bytes->hex-string
     (with-input-from-file "/dev/urandom" (lambda () (read-bytes 12)))))
  (hash-set! email-codes email correct-email-code)
  correct-email-code)

(define (codes-equal? a b)
  ;; Compare case-insensitively since people are weird and might
  ;; type the thing in.
  (string-ci=? a b))

(define (check-code-or email passwd email-code k-true k-false)
  (cond [(and (not (string=? "" email-code))
              (hash-ref email-codes email #f))
         => (λ (correct-email-code)
              (cond
                [(codes-equal? correct-email-code email-code)
                 (define passwd-path (build-path^ users.new-path email))
                 (display-to-file (bcrypt-encode (string->bytes/utf-8 passwd))
                                  passwd-path
                                  #:exists 'replace)
                 (hash-remove! email-codes email)
                 (k-true)]
                [else
                 "wrong-code"]))]
        [else
         (k-false)
         #f]))

(define (send-password-reset-email! email)
  (send-mail-message
   (get-config email-sender-address "pkgs@racket-lang.org")
   "Account password reset for Racket Package Catalog"
   (list email)
   empty empty
   (list
    "Someone tried to login with your email address for an account on the Racket Package Catalog, but failed."
    "If this was you, please use this code to reset your password:"
    ""
    (generate-a-code! email)
    ""
    "This code will expire, so if it is not available, you'll have to try to again.")))

(define (send-account-registration-email! email)
  (send-mail-message
   (get-config email-sender-address "pkgs@racket-lang.org")
   "Account confirmation for Racket Package Catalog"
   (list email)
   empty empty
   (list
    "Someone tried to register your email address for an account on the Racket Package Catalog."
    "If you want to proceed, use this code:"
    ""
    (generate-a-code! email)
    ""
    "This code will expire, so if it is not available, you'll have to try to register again.")))

(define *cors-headers*
  (list (header #"Access-Control-Allow-Origin" #"*")
        (header #"Access-Control-Allow-Methods" #"POST, OPTIONS")
        (header #"Access-Control-Allow-Headers" #"content-type, authorization")))

(define (response/json o)
  (response/output
   (lambda (p)
     (write-json o p))
   #:headers *cors-headers*
   #:mime-type #"application/json"))

(define (wrap-with-cors-handler dispatcher)
  (lambda (req)
    (if (string-ci=? (bytes->string/latin-1 (request-method req)) "options")
        (response/output void #:headers *cors-headers*)
        (dispatcher req))))

(define (api/authenticate req)
  (define raw (request-post-data/raw req))
  (define req-data (read-json (open-input-bytes (or raw #""))))
  (response/json
   (and (hash? req-data)
        (let ((email (hash-ref req-data 'email #f))
              (passwd (hash-ref req-data 'passwd #f))
              (code (hash-ref req-data 'code #f)))
          (and (string? email)
               (string? passwd)
               (string? code)
               (let ()
                 (define (on-successful-authentication)
                   (hasheq 'curation (curation-administrator? email)
                           'superuser (superuser? email)))
                 (match (ensure-authenticate/email+passwd email passwd (λ () #t))
                   ["failed"
                    (check-code-or email passwd code
                                   (λ () (on-successful-authentication))
                                   (λ () (send-password-reset-email! email)))]
                   ["new-user"
                    (check-code-or email passwd code
                                   (λ () #t)
                                   (λ () (send-account-registration-email! email)))]
                   [#t
                    (on-successful-authentication)])))))))

(define (authenticated-json-post-rpc-service req handler)
  (response/json
   (ensure-authenticate
    req
    (lambda ()
      (handler (read-json (open-input-bytes (or (request-post-data/raw req) #""))))))))

(define-syntax-rule (define-authenticated-json-post-rpc-service function-name
                      [(pat ...) body ...] ...)
  (define (function-name req)
    (authenticated-json-post-rpc-service
     req
     (match-lambda
       [(hash-table pat ...) body ...] ...))))

(define (api/package/modify-all req)
  (authenticated-json-post-rpc-service
   req
   (lambda (req-data)
     (and (hash? req-data)
          (let ((pkg (hash-ref req-data 'pkg #f))
                (name (hash-ref req-data 'name #f))
                (description (hash-ref req-data 'description #f))
                (source (hash-ref req-data 'source #f))
                (tags (hash-ref req-data 'tags #f))
                (authors (hash-ref req-data 'authors #f))
                (versions (hash-ref req-data 'versions #f)))
            (and (string? pkg)
                 (string? name)
                 (string? description)
                 (string? source)
                 (or (not tags) (and (list? tags) (andmap valid-tag? tags)))
                 (or (not authors) (and (list? authors)
                                        (pair? authors)
                                        (andmap valid-author? authors)))
                 (or (not versions) (and (list? versions)
                                         (andmap valid-versions-list-entry? versions)))
                 (save-package! #:old-name pkg
                                #:new-name name
                                #:description description
                                #:source source
                                #:tags tags
                                #:authors authors
                                #:versions versions)))))))

(define (valid-versions-list-entry? entry)
  (and (pair? entry)
       (pair? (cdr entry))
       (null? (cddr entry))
       (valid-version? (car entry))
       (string? (cadr entry))))

;; Call ONLY within scope of an ensure-authenticate! (because depends on non-#f current-user))
(define (save-package! #:old-name old-name
                       #:new-name new-name
                       #:description description
                       #:source source
                       #:tags tags0
                       #:authors authors0
                       #:versions versions0)
  (when (not (current-user)) (error 'save-package! "No current-user"))
  (define new-package? (equal? old-name ""))
  (define (do-save! base-hash)
    (let* ((h base-hash)
           (h (cond [authors0
                     (define authors1
                       (if (superuser? (current-user))
                           authors0
                           (set->list (set-add (list->set authors0) (current-user)))))
                     (hash-set h 'author (string-join authors1))]
                    [new-package?
                     (hash-set h 'author (current-user))]
                    [else
                     h]))
           (h (if tags0 (hash-set h 'tags (tags-normalize tags0)) h))
           (h (if versions0
                  (hash-set h 'versions (for/hash [(v versions0)]
                                          (values (car v)
                                                  (hasheq 'source (cadr v) 'checksum ""))))
                  h))
           (h (hash-set h 'name new-name))
           (h (hash-set h 'source source))
           (h (hash-set h 'description description))
           (h (if (hash-has-key? h 'date-added) h
                  (hash-set h 'date-added (current-seconds))))
           (h (hash-set h 'last-edit (current-seconds))))
      (package-info-set! new-name h)))
  (cond
    [(not (andmap valid-author? (or authors0 '())))
     (log! "package ~v/~v: some bad author" old-name new-name)
     #f]
    [(not (andmap valid-tag? (or tags0 '())))
     (log! "package ~v/~v: some bad tag" old-name new-name)
     #f]
    [(not (andmap valid-versions-list-entry? (or versions0 '())))
     (log! "package ~v/~v: some version list entry" old-name new-name)
     #f]
    [new-package?
     (cond
      [(or (package-exists-as new-name)
           (not (valid-name? new-name)))
       (log! "attempt to create package ~v failed" new-name)
       #f]
      [else
       (log! "creating package ~v" new-name)
       (do-save! (hasheq))
       (signal-update! (list new-name))
       #t])]
    [else
     (ensure-package-author
      old-name
      (λ ()
        (cond
          [(not (equal? old-name (package-exists-as old-name)))
           (log! "case mismatch for package name ~s" old-name)
           #f]
          [(equal? new-name old-name)
           (log! "updating package ~v" old-name)
           (do-save! (package-info old-name))
           (signal-update! (list new-name))
           #t]
          [(and (valid-name? new-name)
                (not (package-exists-as new-name)))
           (log! "updating and renaming package ~v to ~v" old-name new-name)
           (do-save! (package-info old-name))
           (package-remove! old-name)
           (signal-update! (list new-name))
           #t]
          [else
           (log! "attempt to rename package ~v to ~v failed" old-name new-name)
           #f])))]))

(define (tags-normalize ts)
  (remove-duplicates (sort ts string-ci<?)))

(define (ensure-package-author pkg f)
  (cond
    [(package-author? pkg (current-user))
     (f)]
    [(superuser? (current-user))
     (log! "user ~v invoked their superpowers to modify package ~v" (current-user) pkg)
     (f)]
    [else
     (log!
      "attempt to modify package ~v by ~v failed because they are not an author of that package"
      pkg
      (current-user))
     #f]))

(define-authenticated-json-post-rpc-service api/package/del
  [(['pkg pkg])
   (ensure-package-author
    pkg
    (λ ()
      (package-remove! pkg)
      (signal-static! empty)
      #f))])

(define-authenticated-json-post-rpc-service api/package/curate
  [(['pkg pkg] ['ring ring])
   (cond
     [(curation-administrator? (current-user))
      (define i (package-info pkg))
      (package-info-set!
       pkg
       (hash-set i 'ring (min 2 (max 0 ring))))
      (signal-static! (list pkg))
      #t]
     [else
      #f])])

(define (package-author? p u)
  (define i (package-info p))
  (cond
    [(hash-has-key? i 'author)
     ;; should almost always be the case (?!?!) but I'm adding this
     ;; check because in the live database, the `compiler-doc` package
     ;; is missing an author, so we need a fallback in order for
     ;; `packages-of` to work.
     (member u (author->list (package-ref i 'author)))]
    [else
     (log! "WARNING: Package ~a is missing an author field" p)
     #f]))

(define (packages-of u)
  (filter (λ (p) (package-author? p u)) (package-list)))

(define-authenticated-json-post-rpc-service api/update
  [()
   (define user-packages (packages-of (current-user)))
   (log! "Packages of ~a: ~v" (current-user) user-packages)
   (signal-update! user-packages)
   #t])

(define (api/notice req)
  (response/json (file->string notice-path)))

(define-values (main-dispatch main-url)
  (dispatch-rules
   ;;---------------------------------------------------------------------------
   ;; User management
   [("api" "authenticate") #:method "post" api/authenticate]
   ;;---------------------------------------------------------------------------
   ;; Wholesale package update of one kind or another
   [("api" "upload") #:method "post" api/upload]
   [("api" "update") #:method "post" api/update]
   ;;---------------------------------------------------------------------------
   ;; Individual package management
   [("api" "package" "del") #:method "post" api/package/del]
   [("api" "package" "modify-all") #:method "post" api/package/modify-all]
   [("api" "package" "curate") #:method "post" api/package/curate]
   ;;---------------------------------------------------------------------------
   ;; Retrieve backend status message (no longer needed?)
   [("api" "notice") api/notice]
   ;;---------------------------------------------------------------------------
   ;; Static resources
   [else redirect-to-static]))

(define-syntax-rule (forever . body)
  (let loop () (begin . body) (loop)))

(define (go)
  (define port (get-config port 9004))
  (define ssl? (get-config ssl? #t))
  (log! "launching on port ~v" port)
  (signal-static! empty)
  (thread
   (λ ()
     (forever
      (log! "update-t: Running scheduled build update.")
      (signal-build-update!)
      (log! "update-t: Running scheduled update.")
      (signal-update!/beat empty)
      (log! "update-t: sleeping for 1 hour")
      (sleep (* 1 60 60)))))
  (serve/servlet
   (wrap-with-cors-handler main-dispatch)
   #:command-line? #t
   ;; xxx I am getting strange behavior on some connections... maybe
   ;; this will help?
   #:connection-close? #t
   #:listen-ip #f
   #:ssl? ssl?
   #:ssl-cert (and ssl? (build-path root "server-cert.pem"))
   #:ssl-key (and ssl? (build-path root "private-key.pem"))
   #:extra-files-paths empty
   #:servlet-regexp #rx""
   #:port port))

(module+ main
  (go))
