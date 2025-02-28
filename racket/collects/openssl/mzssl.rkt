
;; Disabled when `enforce-retry?' is #f:
;;  Warn clients: when a (non-blocking) write fails to write all the
;;   data, the stream is actually committed to writing the given data
;;   in the future. (This requirement comes from the SSL library.)

;; Another warning: data that is written and not buffered may still be
;;  in flight between Racket and the underlying ports. A `flush-output'
;;  won't return until sent data is actually in the underlying port.
;;  (This is due to the fact that unbuffered data cannot be written
;;  without blocking.)

;; One last warning: a write/read must block because a previous
;;  read/write (the opposite direction) didn't finish, and so that
;;  opposite must be completed, first.

#|
TO DO:
 - hostname checking should shutdown SSL negotiation w/ right alert code
 - CRL support (?)
 - alternative hostname checking styles
 - double-check refcounting of X509
|#

#lang racket/base
(require (rename-in racket/contract/base [-> c->])
         ffi/unsafe
         ffi/unsafe/define
         ffi/unsafe/atomic
         ffi/unsafe/alloc
         ffi/unsafe/global
         ffi/file
         ffi/unsafe/custodian
         racket/list
         racket/port
         racket/tcp
         racket/string
         racket/lazy-require
         racket/runtime-path
         "libcrypto.rkt"
         "libssl.rkt")
(lazy-require
 ["private/win32.rkt" (load-win32-store)]
 ["private/macosx.rkt" (load-macosx-keychain)])

(define-logger openssl)

(define protocol-symbol/c
  (or/c 'secure 'auto 'sslv2-or-v3 'sslv2 'sslv3 'tls 'tls11 'tls12))

(define curve-nid-alist
  '((sect163k1 . 721)
    (sect163r1 . 722)
    (sect163r2 . 723)
    (sect193r1 . 724)
    (sect193r2 . 725)
    (sect233k1 . 726)
    (sect233r1 . 727)
    (sect239k1 . 728)
    (sect283k1 . 729)
    (sect283r1 . 730)
    (sect409k1 . 731)
    (sect409r1 . 732)
    (sect571k1 . 733)
    (sect571r1 . 734)
    (secp160k1 . 708)
    (secp160r1 . 709)
    (secp160r2 . 710)
    (secp192k1 . 711)
    (secp224k1 . 712)
    (secp224r1 . 713)
    (secp256k1 . 714)
    (secp384r1 . 715)
    (secp521r1 . 716)
    (prime192v1 . 409)
    (prime256v1 . 415)))

(define curve/c (apply or/c (map car curve-nid-alist)))

(define verify-source/c
  (or/c path-string?
        (list/c 'directory path-string?)
        (list/c 'win32-store string?)
        (list/c 'macosx-keychain path-string?)))

(provide
 ssl-dh4096-param-path
 (contract-out
  [ssl-available? boolean?]
  [ssl-load-fail-reason (or/c #f string?)]
  [ssl-make-client-context
   (->* ()
        (protocol-symbol/c
         #:private-key (or/c (list/c 'pem path-string?) (list/c 'der path-string?) #f)
         #:certificate-chain (or/c path-string? #f))
        ssl-client-context?)]
  [ssl-secure-client-context
   (c-> ssl-client-context?)]
  [ssl-make-server-context
   (->* ()
        (protocol-symbol/c
         #:private-key (or/c (list/c 'pem path-string?) (list/c 'der path-string?) #f)
         #:certificate-chain (or/c path-string? #f))
        ssl-server-context?)]
  [ssl-server-context-enable-dhe!
   (->* (ssl-server-context?) (path-string?) void?)]
  [ssl-server-context-enable-ecdhe!
   (->* (ssl-server-context?) (curve/c) void?)]
  [ssl-client-context?
   (c-> any/c boolean?)]
  [ssl-server-context?
   (c-> any/c boolean?)]
  [ssl-context?
   (c-> any/c boolean?)]
  [ssl-load-certificate-chain!
   (c-> (or/c ssl-context? ssl-listener?) path-string? void?)]
  [ssl-load-private-key!
   (->* ((or/c ssl-context? ssl-listener?) path-string?)
        (any/c any/c)
        void?)]
  [ssl-load-verify-root-certificates!
   (c-> (or/c ssl-context? ssl-listener? ssl-port?)
        path-string?
        void?)]
  [ssl-load-verify-source!
   (c-> ssl-context?
        verify-source/c
        void?)]
  [ssl-load-suggested-certificate-authorities!
   (c-> (or/c ssl-context? ssl-listener?)
        path-string?
        void?)]
  [ssl-set-ciphers!
   (c-> ssl-context? string? void?)]
  [ssl-set-server-name-identification-callback!
   (c-> ssl-server-context? (c-> string? (or/c ssl-server-context? #f)) void?)]
  [ssl-seal-context!
   (c-> ssl-context? void?)]
  [ssl-default-verify-sources
   (parameter/c (listof verify-source/c))]
  [ssl-load-default-verify-sources!
   (c-> ssl-context? void?)]
  [ssl-set-verify!
   (c-> (or/c ssl-context? ssl-listener? ssl-port?)
        any/c
        void?)]
  [ssl-try-verify!
   (c-> (or/c ssl-context? ssl-listener? ssl-port?)
        any/c
        void?)]
  [ssl-set-verify-hostname!
   (c-> ssl-context? any/c void?)]
  [ssl-peer-verified?
   (c-> ssl-port? boolean?)]
  [ssl-peer-certificate-hostnames
   (c-> ssl-port? (listof string?))]
  [ssl-peer-check-hostname
   (c-> ssl-port? string? boolean?)]
  [ssl-peer-subject-name
   (c-> ssl-port? (or/c bytes? #f))]
  [ssl-peer-issuer-name
   (c-> ssl-port? (or/c bytes? #f))]
  [ports->ssl-ports
   (->* [input-port?
         output-port?]
        [#:mode (or/c 'connect 'accept)
         #:context ssl-context?
         #:encrypt protocol-symbol/c
         #:close-original? any/c
         #:shutdown-on-close? any/c
         #:error/ssl procedure?
         #:hostname (or/c string? #f)]
        (values input-port? output-port?))]
  [ssl-listen
   (->* [(integer-in 1 (sub1 (expt 2 16)))]
        [exact-nonnegative-integer?
         any/c
         (or/c string? #f)
         (or/c ssl-server-context? protocol-symbol/c)]
        ssl-listener?)]
  [ssl-close
   (c-> ssl-listener? void?)]
  [ssl-accept
   (c-> ssl-listener?
        (values input-port? output-port?))]
  [ssl-accept/enable-break
   (c-> ssl-listener?
        (values input-port? output-port?))]
  [ssl-connect
   (->* [string?
         (integer-in 1 (sub1 (expt 2 16)))]
        [(or/c ssl-client-context? protocol-symbol/c)]
        (values input-port? output-port?))]
  [ssl-connect/enable-break
   (->* [string?
         (integer-in 1 (sub1 (expt 2 16)))]
        [(or/c ssl-client-context? protocol-symbol/c)]
        (values input-port? output-port?))]
  [ssl-listener?
   (c-> any/c boolean?)]
  [ssl-addresses
   (->* [(or/c ssl-listener? ssl-port?)]
        [any/c]
        any)]
  [ssl-abandon-port
   (c-> ssl-port? void?)]
  [ssl-port?
   (c-> any/c boolean?)])
 ssl-max-client-protocol
 ssl-max-server-protocol
 supported-client-protocols
 supported-server-protocols)

(define ssl-load-fail-reason
  (or libssl-load-fail-reason
      libcrypto-load-fail-reason))

(define libmz (ffi-lib #f))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SSL bindings and constants

(define-ffi-definer define-crypto libcrypto
  #:default-make-fail make-not-available)
(define-ffi-definer define-ssl libssl
  #:default-make-fail make-not-available)
(define-ffi-definer define-mzscheme libmz)

(define-cpointer-type _BIO_METHOD*)
(define-cpointer-type _BIO*)
(define-cpointer-type _SSL_METHOD*)
(define-cpointer-type _SSL_CTX*)
(define-cpointer-type _SSL*)
(define-cpointer-type _X509_NAME*)
(define-cpointer-type _X509_NAME_ENTRY*)
(define-cpointer-type _X509*)
(define-cpointer-type _ASN1_STRING*)
(define-cpointer-type _STACK*)
(define-cpointer-type _DH*)
(define-cpointer-type _EC_KEY*)
(define-cstruct _GENERAL_NAME ([type _int] [d _ASN1_STRING*]))

(define-ssl SSLv2_client_method (_fun -> _SSL_METHOD*) #:fail (lambda () #f))
(define-ssl SSLv2_server_method (_fun -> _SSL_METHOD*) #:fail (lambda () #f))
(define-ssl SSLv3_client_method (_fun -> _SSL_METHOD*) #:fail (lambda () #f))
(define-ssl SSLv3_server_method (_fun -> _SSL_METHOD*) #:fail (lambda () #f))
(define-ssl SSLv23_client_method (_fun -> _SSL_METHOD*) #:fail (lambda () #f))
(define-ssl SSLv23_server_method (_fun -> _SSL_METHOD*) #:fail (lambda () #f))
(define-ssl TLSv1_client_method (_fun -> _SSL_METHOD*) #:fail (lambda () #f))
(define-ssl TLSv1_server_method (_fun -> _SSL_METHOD*) #:fail (lambda () #f))
(define-ssl TLSv1_1_client_method (_fun -> _SSL_METHOD*) #:fail (lambda () #f))
(define-ssl TLSv1_1_server_method (_fun -> _SSL_METHOD*) #:fail (lambda () #f))
(define-ssl TLSv1_2_client_method (_fun -> _SSL_METHOD*) #:fail (lambda () #f))
(define-ssl TLSv1_2_server_method (_fun -> _SSL_METHOD*) #:fail (lambda () #f))

;; OpenSSL 1.1 defines TLS_client_method(), instead of making SSLv23_client_method()
;; actually select the the latest
(define-ssl TLS_client_method (_fun -> _SSL_METHOD*) #:fail (lambda () SSLv23_client_method))
(define-ssl TLS_server_method (_fun -> _SSL_METHOD*) #:fail (lambda () SSLv23_server_method))

(define-crypto DH_free (_fun _DH* -> _void) #:wrap (deallocator))
(define-crypto EC_KEY_free (_fun _EC_KEY* -> _void) #:wrap (deallocator))

(define-crypto EC_KEY_new_by_curve_name (_fun _int -> _EC_KEY*) #:wrap (allocator EC_KEY_free))

(define-crypto BIO_s_mem (_fun -> _BIO_METHOD*))
(define-crypto BIO_new (_fun _BIO_METHOD* -> _BIO*/null))
(define-crypto BIO_new_mem_buf (_fun _pointer _int -> _BIO*))
(define-crypto BIO_free (_fun _BIO* -> _void))

(define-crypto BIO_read (_fun _BIO* _bytes _int -> _int))
(define-crypto BIO_write (_fun _BIO* _bytes _int -> _int))
(define-crypto BIO_ctrl (_fun _BIO* _int _long _long -> _long))
(define (BIO_set_mem_eof_return b v)
  (BIO_ctrl b BIO_C_SET_BUF_MEM_EOF_RETURN v 0))

(define-ssl SSL_CTX_free (_fun _SSL_CTX* -> _void)
  #:wrap (deallocator))
(define-ssl SSL_CTX_new (_fun _SSL_METHOD* -> _SSL_CTX*/null)
  #:wrap (allocator SSL_CTX_free))
(define-ssl SSL_CTX_callback_ctrl
  (_fun _SSL_CTX* _int
        (_fun #:in-original-place? #t _SSL* _pointer _pointer -> _int)
        -> _long))
(define-ssl SSL_CTX_ctrl (_fun _SSL_CTX* _int _long _pointer -> _long))
(define (SSL_CTX_set_mode ctx m)
  (SSL_CTX_ctrl ctx SSL_CTRL_MODE m #f))
(define (SSL_CTX_set_options ctx opts)
  (SSL_CTX_ctrl ctx SSL_CTRL_OPTIONS opts #f))

(define-ssl SSL_CTX_set_verify (_fun _SSL_CTX* _int _pointer -> _void))
(define-ssl SSL_CTX_use_certificate_chain_file (_fun _SSL_CTX* _path -> _int))
(define-ssl SSL_CTX_load_verify_locations (_fun _SSL_CTX* _path _path -> _int))
(define-ssl SSL_CTX_set_client_CA_list (_fun _SSL_CTX* _X509_NAME* -> _int))
(define-ssl SSL_CTX_set_session_id_context (_fun _SSL_CTX* _bytes _int -> _int))
(define-ssl SSL_CTX_use_RSAPrivateKey_file (_fun _SSL_CTX* _path _int -> _int))
(define-ssl SSL_CTX_use_PrivateKey_file (_fun _SSL_CTX* _path _int -> _int))
(define-ssl SSL_load_client_CA_file (_fun _path -> _X509_NAME*/null))
(define-ssl SSL_CTX_set_cipher_list (_fun _SSL_CTX* _string -> _int))

(define-ssl SSL_free (_fun _SSL* -> _void)
  #:wrap (deallocator))
(define-ssl SSL_new (_fun _SSL_CTX* -> _SSL*)
  #:wrap (allocator SSL_free))
(define-ssl SSL_set_bio (_fun _SSL* _BIO* _BIO* -> _void))
(define-ssl SSL_connect (_fun _SSL* -> _int))
(define-ssl SSL_accept (_fun _SSL* -> _int))
(define-ssl SSL_read (_fun _SSL* _bytes _int -> _int))
(define-ssl SSL_peek (_fun _SSL* _bytes _int -> _int))
(define-ssl SSL_write (_fun _SSL* _bytes _int -> _int))
(define-ssl SSL_shutdown (_fun _SSL* -> _int))
(define-ssl SSL_get_verify_result (_fun _SSL* -> _long))
(define-ssl SSL_get_servername (_fun _SSL* _int -> _string))
(define-ssl SSL_set_verify (_fun _SSL* _int _pointer -> _void))
(define-ssl SSL_set_session_id_context (_fun _SSL* _bytes _int -> _int))
(define-ssl SSL_renegotiate (_fun _SSL* -> _int))
(define-ssl SSL_renegotiate_pending (_fun _SSL* -> _int))
(define-ssl SSL_do_handshake (_fun _SSL* -> _int))
(define-ssl SSL_ctrl/bytes (_fun _SSL* _int _long _bytes/nul-terminated -> _long)
  #:c-id SSL_ctrl)
(define-ssl SSL_set_SSL_CTX (_fun _SSL* _SSL_CTX* -> _SSL_CTX*))

(define-crypto X509_free (_fun _X509* -> _void)
  #:wrap (deallocator))
(define-ssl SSL_get_peer_certificate (_fun _SSL* -> _X509*/null)
  #:wrap (allocator X509_free))

(define-crypto X509_get_subject_name (_fun _X509* -> _X509_NAME*))
(define-crypto X509_get_issuer_name (_fun _X509* -> _X509_NAME*))
(define-crypto X509_NAME_oneline (_fun _X509_NAME* _bytes _int -> _bytes))

(define-ssl SSL_get_error (_fun _SSL* _int -> _int))

(define-crypto ERR_get_error (_fun -> _long))
(define-crypto ERR_error_string_n (_fun _long _bytes _long -> _void))

(define-ssl SSL_library_init (_fun -> _void)
  ;; No SSL_library_init for 1.1 or later:
  #:fail (lambda () void))
(define-ssl SSL_load_error_strings (_fun -> _void)
  ;; No SSL_load_error_strings for 1.1 or later:
  #:fail (lambda () void))

(define-crypto GENERAL_NAME_free _fpointer)
(define-crypto PEM_read_bio_DHparams (_fun _BIO* _pointer _pointer _pointer -> _DH*) #:wrap (allocator DH_free))
(define-crypto ASN1_STRING_length (_fun _ASN1_STRING* -> _int))
(define-crypto ASN1_STRING_data (_fun _ASN1_STRING* -> _pointer))
(define-crypto X509_NAME_get_index_by_NID (_fun _X509_NAME* _int _int -> _int))
(define-crypto X509_NAME_get_entry (_fun _X509_NAME* _int -> _X509_NAME_ENTRY*/null))
(define-crypto X509_NAME_ENTRY_get_data (_fun _X509_NAME_ENTRY* -> _ASN1_STRING*))
(define-crypto X509_get_ext_d2i (_fun _X509* _int _pointer _pointer -> _STACK*/null))
(define-crypto sk_num (_fun _STACK* -> _int)
  #:fail (lambda ()
           (define-crypto OPENSSL_sk_num (_fun _STACK* -> _int))
           OPENSSL_sk_num))
(define-crypto sk_GENERAL_NAME_value (_fun _STACK* _int -> _GENERAL_NAME-pointer)
  #:c-id sk_value
  #:fail (lambda ()
           (define-crypto OPENSSL_sk_value (_fun _STACK* _int -> _GENERAL_NAME-pointer))
           OPENSSL_sk_value))
(define-crypto sk_pop_free (_fun _STACK* _fpointer -> _void)
  #:fail (lambda ()
           (define-crypto OPENSSL_sk_pop_free (_fun _STACK* _fpointer -> _void))
           OPENSSL_sk_pop_free))

;; (define-crypto X509_get_default_cert_area (_fun -> _string))
(define-crypto X509_get_default_cert_dir  (_fun -> _string))
(define-crypto X509_get_default_cert_file (_fun -> _string))
(define-crypto X509_get_default_cert_dir_env (_fun -> _string))
(define-crypto X509_get_default_cert_file_env (_fun -> _string))

(define (x509-root-sources)
  (cond
    [libcrypto
     ;; Workaround for natipkg openssl library: the default cert locations vary
     ;; from distro to distro, and there is no one configuration that works with
     ;; all. So build natipkg libssl.so with `--openssldir="/RACKET_USE_ALT_PATH"`
     ;; and this code will override with better guesses.
     ;; Cert locations for various distros:
     ;;   Debian: dir=/etc/ssl/certs, file=/etc/ssl/certs/ca-certificates.crt (prefer dir!)
     ;;   RedHat: file=/etc/pki/tls/certs/ca-bundle.crt; /etc/ssl/certs exists but useless!
     ;;   OpenSUSE: dir=/etc/ssl/certs, file=/var/lib/ca-certificates/ca-bundle.pem (prefer dir!)
     ;; So try file=/etc/pki/tls/certs/ca-bundle.crt, dir=/etc/ssl/certs.
     (define (use-alt-path? p) (regexp-match? #rx"^/RACKET_USE_ALT_PATH" p))
     (define (subst-cert-file p)
       (cond [(use-alt-path? p)
              (log-openssl-debug "cert file path is ~s; using alternatives" p)
              (filter file-exists? '("/etc/pki/tls/certs/ca-bundle.crt"))]
             [else p]))
     (define (subst-cert-dir p)
       (cond [(use-alt-path? p)
              (log-openssl-debug "cert dir path is ~s; using alternatives" p)
              (filter directory-exists? '("/etc/ssl/certs"))]
             [else p]))
     ;; ----
     (define dir-sep (case (system-type) [(windows) ";"] [else ":"]))
     (define cert-file0
       (or (getenv (X509_get_default_cert_file_env)) (X509_get_default_cert_file)))
     (define cert-dirs0
       (or (getenv (X509_get_default_cert_dir_env)) (X509_get_default_cert_dir)))
     ;; Use path-string? filter to avoid {file,directory}-exists? error on "".
     (define cert-files
       (filter path-string? (flatten (map subst-cert-file (list cert-file0)))))
     (define cert-dirs
       (filter path-string? (flatten (map subst-cert-dir (string-split cert-dirs0 dir-sep)))))
     ;; Log error only if *no* cert source exists (eg, on Debian/Ubuntu, default
     ;; cert file does not exist).
     (unless (or (ormap file-exists? cert-files) (ormap directory-exists? cert-dirs))
       (log-openssl-error
        "x509-root-sources: cert sources do not exist: ~s, ~s; ~a"
        cert-file0 cert-dirs0
        (format "override using ~a, ~a"
                (X509_get_default_cert_file_env)
                (X509_get_default_cert_dir_env))))
     (log-openssl-debug "using cert sources: ~s, ~s" cert-files cert-dirs)
     (append cert-files (map (lambda (p) (list 'directory p)) cert-dirs))]
    [else null]))

(define ssl-default-verify-sources
  (make-parameter
   (case (system-type)
     [(windows)
      ;; On Windows, x509-root-sources produces paths like "/usr/local/ssl/certs", which
      ;; aren't useful. So just skip them.
      '((win32-store "ROOT"))]
     [(macosx)
      '((macosx-keychain "/System/Library/Keychains/SystemRootCertificates.keychain"))]
     [else
      (x509-root-sources)])))

(define X509_V_OK 0)

(define SSL_ERROR_SSL 1)
(define SSL_ERROR_WANT_READ 2)
(define SSL_ERROR_WANT_WRITE 3)
(define SSL_ERROR_SYSCALL 5)
(define SSL_ERROR_ZERO_RETURN 6)

(define BIO_C_SET_BUF_MEM_EOF_RETURN 130)

(define SSL_FILETYPE_PEM 1)
(define SSL_FILETYPE_ASN1 2)

(define SSL_VERIFY_NONE #x00)
(define SSL_VERIFY_PEER #x01)
(define SSL_VERIFY_FAIL_IF_NO_PEER_CERT #x02)

(define SSL_MODE_ENABLE_PARTIAL_WRITE #x01)
(define SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER #x02)
(define SSL_CTRL_MODE 33)

(define NID_subject_alt_name 85)
(define NID_commonName 13)
(define GEN_DNS 2)

(define SSL_CTRL_OPTIONS 32)
(define SSL_CTRL_SET_TLSEXT_SERVERNAME_CB 53)
(define SSL_CTRL_SET_TLSEXT_HOSTNAME 55)
(define SSL_CTRL_SET_TMP_DH 3)
(define SSL_CTRL_SET_TMP_ECDH 4)

(define SSL_OP_NO_SSLv2    #x01000000)
(define SSL_OP_NO_SSLv3    #x02000000)
(define SSL_OP_NO_TLSv1    #x04000000)
(define SSL_OP_NO_TLSv1_2  #x08000000)
(define SSL_OP_NO_TLSv1_1  #x10000000)

(define SSL_OP_SINGLE_ECDH_USE #x00080000)
(define SSL_OP_SINGLE_DH_USE #x00100000)

(define TLSEXT_NAMETYPE_host_name 0)

(define SSL_TLSEXT_ERR_OK 0)
(define SSL_TLSEXT_ERR_NOACK 3)

(define-runtime-path ssl-dh4096-param-path "dh4096.pem")

;; Make this bigger than 4096 to accommodate at least
;; 4096 of unencrypted data
(define BUFFER-SIZE 8000)

;; The man pages for SSL_read and SSL_write say that they must be
;; retried with the same arguments when they return SSL_ERROR_WANT_READ
;; or SSL_ERROR_WANT_WRITE.  This may not actually be true, especially
;; when SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER is used, and "retry" may or
;; may not mean "retry without doing other things first". Set `enforce-retry?'
;; to #t to obey the manpage and retry without doing other things, which
;; has an implicitation for clients as noted at the top of this file.
(define enforce-retry? #f)

;; Needed for `renegotiate' prior to v1.1:
(define-cstruct _ssl_struct ([version _int]
                             [type _int]
                             [method _pointer]
                             [rbio _pointer]
                             [wbio _pointer]
                             [bbio _pointer]
                             [rwstate _int]
                             [in_handshake _int]
                             [handshake_func _fpointer]
                             [server _int]
                             [new_session _int]
                             [quiet_shutdown _int]
                             [shutdown _int]
                             [state _int]
                             ;; ...
                             ))

(define SSL_ST_ACCEPT #x2000)

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Error handling

(define-syntax with-failure
  (syntax-rules ()
    [(_ thunk body ...)
     (with-handlers ([exn? (lambda (exn) (thunk) (raise exn))])
       body ...)]))

(define (get-error-message id)
  (let* ([buffer (make-bytes 512)])
    (ERR_error_string_n id buffer (bytes-length buffer))
    (regexp-match #rx#"^[^\0]*" buffer)))

(define (check-valid v who what)
  (when (ptr-equal? v #f)
    (let ([id (ERR_get_error)])
      (error who "~a failed ~a" what (get-error-message id)))))

(define (error/network who fmt . args)
  (raise (make-exn:fail:network
          (format "~a: ~a" who (apply format fmt args))
          (current-continuation-marks))))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Atomic blocks

(define-syntax-rule (atomically body ...)
  (call-as-atomic (lambda () body ...)))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Structs

(define-struct ssl-context (ctx [verify-hostname? #:mutable] [sealed? #:mutable]))
(define-struct (ssl-client-context ssl-context) ())
(define-struct (ssl-server-context ssl-context) ([servername-callback #:mutable #:auto]))

(define-struct ssl-listener (l mzctx)
  #:property prop:evt (lambda (lst) (wrap-evt (ssl-listener-l lst) 
                                              (lambda (x) lst))))

;; internal:
(define-struct mzssl (ssl i o r-bio w-bio pipe-r pipe-w 
                    buffer lock 
                    w-closed? r-closed?
                    flushing? must-write must-read
                    refcount 
                    close-original? shutdown-on-close?
                          error
                          server?)
  #:mutable)

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Errors

(define (do-save-errors thunk ssl)
  ;; Atomically run a function and get error results
  ;; so that this library is thread-safe (at the level of Racket threads)
  (atomically
   (define v (thunk))
   (define e (if (positive? v)
                 0
                 (SSL_get_error ssl v)))
   (define unknown "(unknown error)")
   (define estr
     (cond
      [(= e SSL_ERROR_SSL)
       (get-error-message (ERR_get_error))]
      [(= e SSL_ERROR_SYSCALL)
       (define v (ERR_get_error))
       (if (zero? v)
           unknown
           (get-error-message v))]
      [else unknown]))
   (values v e estr)))

(define-syntax-rule (save-errors e ssl)
  (do-save-errors (lambda () e) ssl))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Contexts, certificates, etc.

(define default-encrypt 'auto)

(define (encrypt->method who e client?)
  (define f
    (case e
      [(secure auto sslv2-or-v3)
       (if client? TLS_client_method TLS_server_method)]
      [(sslv2)
       (if client? SSLv2_client_method SSLv2_server_method)]
      [(sslv3)
       (if client? SSLv3_client_method SSLv3_server_method)]
      [(tls)
       (if client? TLSv1_client_method TLSv1_server_method)]
      [(tls11)
       (if client? TLSv1_1_client_method TLSv1_1_server_method)]
      [(tls12)
       (if client? TLSv1_2_client_method TLSv1_2_server_method)]
      [else
       (error 'encrypt->method "internal error, unknown encrypt: ~e" e)]))
  (unless f
    (raise (exn:fail:unsupported
            (format "~a: requested protocol not supported~a\n  requested: ~e"
                    who
                    (if ssl-available?
                        ""
                        ";\n SSL not available; check `ssl-load-fail-reason'")
                    e)
            (current-continuation-marks))))
  (f))

(define (filter-available l)
  (cond
   [(null? l) null]
   [(cadr l) (cons (car l) (filter-available (cddr l)))]
   [else (filter-available (cddr l))]))

;; Keep symbols in best-last order for ssl-max-{client,server}-protocol.
(define (supported-client-protocols)
  (filter-available
   (list 'secure TLS_client_method
         'auto TLS_client_method
         'sslv2-or-v3 TLS_client_method
         ;; 'sslv2 SSLv2_client_method --- always fails in modern OpenSSL
         'sslv3 SSLv3_client_method
         'tls TLSv1_client_method
         'tls11 TLSv1_1_client_method
         'tls12 TLSv1_2_client_method)))
(define (supported-server-protocols)
  (filter-available
   (list 'secure TLS_server_method
         'auto TLS_server_method
         'sslv2-or-v3 TLS_server_method
         ;; 'sslv2 SSLv2_server_method --- always fails in modern OpenSSL
         'sslv3 SSLv3_server_method
         'tls TLSv1_server_method
         'tls11 TLSv1_1_server_method
         'tls12 TLSv1_2_server_method)))

(define (ssl-max-client-protocol)
  (let ([protocols (supported-client-protocols)])
    (and (pair? protocols) (last protocols))))

(define (ssl-max-server-protocol)
  (let ([protocols (supported-server-protocols)])
    (and (pair? protocols) (last protocols))))

(define (make-context who protocol-symbol client? priv-key cert-chain)
  (define ctx (make-raw-context who protocol-symbol client?))
  (define mzctx ((if client? make-ssl-client-context make-ssl-server-context) ctx #f #f))
  (when cert-chain (ssl-load-certificate-chain! mzctx cert-chain))
  (cond [(and (pair? priv-key) (eq? (car priv-key) 'pem))
         (ssl-load-private-key! mzctx (cadr priv-key) #f #f)]
        [(and (pair? priv-key) (eq? (car priv-key) 'der))
         (ssl-load-private-key! mzctx (cadr priv-key) #f #t)]
        [else (void)])
  mzctx)

(define (make-raw-context who protocol-symbol client?)
  (define meth (encrypt->method who protocol-symbol client?))
  (define ctx
    (atomically ;; connect SSL_CTX_new to subsequent check-valid (ERR_get_error)
     (let ([ctx (SSL_CTX_new meth)])
       (check-valid ctx who "context creation")
       ctx)))
  (unless (memq protocol-symbol '(sslv2 sslv3))
    (SSL_CTX_set_options ctx (bitwise-ior SSL_OP_NO_SSLv2 SSL_OP_NO_SSLv3)))
  (SSL_CTX_set_mode ctx (bitwise-ior SSL_MODE_ENABLE_PARTIAL_WRITE
                                     SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER))
  ctx)

(define (need-ctx-free? context-or-encrypt-method)
  (and (symbol? context-or-encrypt-method)
       (not (eq? context-or-encrypt-method 'secure))))

(define (ssl-make-client-context [protocol-symbol default-encrypt]
                                 #:private-key [priv-key #f]
                                 #:certificate-chain [cert-chain #f])
  (cond [(and (eq? protocol-symbol 'secure) (not priv-key) (not cert-chain))
         (ssl-secure-client-context)]
        [else
         (define ctx (make-context 'ssl-make-client-context protocol-symbol #t priv-key cert-chain))
         (when (eq? protocol-symbol 'secure) (secure-client-context! ctx))
         ctx]))

(define (ssl-make-server-context [protocol-symbol default-encrypt]
                                 #:private-key [priv-key #f]
                                 #:certificate-chain [cert-chain #f])
  (make-context 'ssl-make-server-context protocol-symbol #f priv-key cert-chain))

(define (get-context who context-or-encrypt-method client?
                     #:need-unsealed? [need-unsealed? #f])
  (if (ssl-context? context-or-encrypt-method)
      (extract-ctx who need-unsealed? context-or-encrypt-method)
      (if (and client? (eq? context-or-encrypt-method 'secure))
          (ssl-context-ctx (ssl-secure-client-context))
          (make-raw-context who context-or-encrypt-method client?))))

(define (get-context/listener who ssl-context-or-listener [fail? #t]
                              #:need-unsealed? [need-unsealed? #f])
  (cond
   [(ssl-context? ssl-context-or-listener)
    (extract-ctx who need-unsealed? ssl-context-or-listener)]
   [(ssl-listener? ssl-context-or-listener)
    (extract-ctx who need-unsealed? (ssl-listener-mzctx ssl-context-or-listener))]
   [else
    (if fail?
        (raise-argument-error who
                              "(or/c ssl-context? ssl-listener?)"
                              ssl-context-or-listener)
        #f)]))

(define (extract-ctx who need-unsealed? mzctx)
  (when (and need-unsealed? (ssl-context-sealed? mzctx))
    (error who "context is sealed; no further changes are allowed"))
  (ssl-context-ctx mzctx))

(define (ssl-seal-context! mzctx)
  (set-ssl-context-sealed?! mzctx #t))

(define (ssl-server-context-enable-ecdhe! context [name 'secp521r1])
  (define (symbol->nid name)
    (cond [(assq name curve-nid-alist)
           => cdr]
          [else
           (error 'ssl-server-context-enable-ecdhe!
                  "bad curve name\n  curve name: ~e" name)]))
  (define ctx (extract-ctx 'ssl-server-context-enable-ecdhe! #t context))
  (define key (EC_KEY_new_by_curve_name (symbol->nid name)))
  (check-valid key 'ssl-server-context-enable-ecdhe! "enabling ECDHE")
  (unless (= 1 (SSL_CTX_ctrl ctx SSL_CTRL_SET_TMP_ECDH 0 key))
    (error 'ssl-server-context-enable-ecdhe! "enabling ECDHE"))
  (SSL_CTX_ctrl ctx SSL_CTRL_OPTIONS SSL_OP_SINGLE_ECDH_USE #f)
  (void))

(define (ssl-server-context-enable-dhe! context [path ssl-dh4096-param-path])
  (define params (call-with-input-file path port->bytes))
  (define params-bio (BIO_new_mem_buf params (bytes-length params)))
  (check-valid params-bio 'ssl-server-context-enable-dhe! "loading Diffie-Hellman parameters")
  (with-failure
    (lambda ()
      (BIO_free params-bio))
    (define ctx (extract-ctx 'ssl-server-context-enable-dhe! #t context))
    (define dh (PEM_read_bio_DHparams params-bio #f #f #f))
    (check-valid dh 'ssl-server-context-enable-dhe! "loading Diffie-Hellman parameters")
    (unless (= 1 (SSL_CTX_ctrl ctx SSL_CTRL_SET_TMP_DH 0 dh))
      (error 'ssl-server-context-enable-dhe! "failed to enable DHE"))
    (SSL_CTX_ctrl ctx SSL_CTRL_OPTIONS SSL_OP_SINGLE_DH_USE #f)
    (void)))

(define (ssl-load-... who load-it ssl-context-or-listener pathname
                      #:try? [try? #f])
  (let ([ctx (get-context/listener who ssl-context-or-listener
                                   #:need-unsealed? #t)])
    (let ([path 
           (path->complete-path (cleanse-path pathname)
                                (current-directory))])
      (security-guard-check-file who path '(read))
      (atomically ;; for to connect ERR_get_error to `load-it'
       (let ([n (load-it ctx path)])
         (unless (or (= n 1) try?)
           (error who "load failed from: ~e ~a"
                  pathname
                  (get-error-message (ERR_get_error)))))))))

(define (ssl-load-certificate-chain! ssl-context-or-listener pathname)
  (ssl-load-... 'ssl-load-certificate-chain! 
          SSL_CTX_use_certificate_chain_file
          ssl-context-or-listener pathname))

(define (ssl-load-suggested-certificate-authorities! ssl-listener pathname)
  (ssl-load-... 'ssl-load-suggested-certificate-authorities! 
          (lambda (ctx path)
            (let ([stk (SSL_load_client_CA_file path)])
              (if (ptr-equal? stk #f)
                  0
                  (begin
                    (SSL_CTX_set_client_CA_list ctx stk)
                    1))))
          ssl-listener pathname))

(define (ssl-load-private-key! ssl-context-or-listener pathname
                               [rsa? #t] [asn1? #f])
  (ssl-load-...
   'ssl-load-private-key!
   (lambda (ctx path)
     ((if rsa? SSL_CTX_use_RSAPrivateKey_file SSL_CTX_use_PrivateKey_file)
      ctx path
      (if asn1? SSL_FILETYPE_ASN1 SSL_FILETYPE_PEM)))
   ssl-context-or-listener pathname))

(define (ssl-load-verify-root-certificates! scl src)
  (ssl-load-... 'ssl-load-verify-root-certificates!
                (lambda (a b) (SSL_CTX_load_verify_locations a b #f))
                scl src))

(define (ssl-load-verify-source! context src #:try? [try? #f])
  (define (bad-source)
    (error 'ssl-load-verify-source!
           "internal error: bad source: ~e" src))
  (cond [(path-string? src)
         (ssl-load-... 'ssl-load-verify-source!
                       (lambda (a b) (SSL_CTX_load_verify_locations a b #f))
                       context src #:try? try?)]
        [(and (list? src) (= (length src) 2))
         (let ([tag (car src)]
               [val (cadr src)])
           (case tag
             [(directory)
              (ssl-load-... 'ssl-load-verify-source!
                            (lambda (a b) (SSL_CTX_load_verify_locations a #f b))
                            context val #:try? try?)]
             [(win32-store)
              (let ([ctx (get-context/listener 'ssl-load-verify-source! context
                                               #:need-unsealed? #t)])
                (load-win32-store 'ssl-load-verify-source!
                                               ctx val try?))]
             [(macosx-keychain)
              (let ([ctx (get-context/listener 'ssl-load-verify-source! context
                                               #:need-unsealed? #t)])
                (load-macosx-keychain 'ssl-load-verify-source! ctx val try?))]
             [else (bad-source)]))]
        [else (bad-source)]))

(define (ssl-load-default-verify-sources! ctx)
  (for ([src (in-list (ssl-default-verify-sources))])
    (ssl-load-verify-source! ctx src #:try? #t)))

(define (ssl-set-ciphers! context cipher-spec)
  (let* ([ctx (extract-ctx 'ssl-set-ciphers! #t context)]
         [result (SSL_CTX_set_cipher_list ctx cipher-spec)])
    (unless (= result 1)
      (error 'ssl-set-ciphers! "setting cipher list failed"))
    (void)))

(define (ssl-set-server-name-identification-callback! ssl-context proc)
  (let ([cb (lambda (ssl ad ptr)
	      (let ([ret (proc (SSL_get_servername ssl TLSEXT_NAMETYPE_host_name))])
		(if (ssl-server-context? ret)
		    (begin
		      (SSL_set_SSL_CTX ssl (extract-ctx 'callback #f ret))
		      SSL_TLSEXT_ERR_OK)
		    ; this isn't an error, it just means "no change necessary"
		    SSL_TLSEXT_ERR_NOACK)))])

    ; hold onto cb so that the garbage collector doesn't reclaim
    ; the function that openssl is holding onto.
    (set-ssl-server-context-servername-callback! ssl-context cb)

    (unless (= (SSL_CTX_callback_ctrl
		(extract-ctx 'ssl-set-server-name-identification-callback! #t ssl-context)
		SSL_CTRL_SET_TLSEXT_SERVERNAME_CB
		cb) 1)
	    (error 'ssl-set-server-name-identification-callback! "setting server name identification callback failed"))))

(define (ssl-set-verify-hostname! ssl-context on?)
  ;; to check not sealed:
  (void (extract-ctx 'ssl-set-verify-hostname! #t ssl-context))
  (set-ssl-context-verify-hostname?! ssl-context (and on? #t)))

(define (ssl-try-verify! ssl-context-or-listener-or-port on?)
  (do-ssl-set-verify! ssl-context-or-listener-or-port on?
                      'ssl-try-verify!
                      SSL_VERIFY_PEER))

(define (ssl-set-verify! ssl-context-or-listener-or-port on?)
  (do-ssl-set-verify! ssl-context-or-listener-or-port on?
                      'ssl-set-verify!
                      (bitwise-ior SSL_VERIFY_PEER
                                   SSL_VERIFY_FAIL_IF_NO_PEER_CERT)))

(define (do-ssl-set-verify! ssl-context-or-listener-or-port on? who mode)
  (cond
   [(get-context/listener who
                          ssl-context-or-listener-or-port
                          #f
                          #:need-unsealed? #t)
    => (lambda (ctx)
         ;; required by openssl. This is more for when calling i2d_SSL_SESSION/d2i_SSL_SESSION
         ;; for instance if we were saving sessions in a database etc... We aren't using that
         ;; so a generic session name should be fine.
         (let ([bytes #"racket"])
           (SSL_CTX_set_session_id_context ctx bytes (bytes-length bytes)))
         
         (SSL_CTX_set_verify ctx
                             (if on?
                                 mode
                                 SSL_VERIFY_NONE)
                             #f))]
   [else
    (let-values ([(mzssl input?) (lookup who ssl-context-or-listener-or-port)])
      (SSL_set_verify (mzssl-ssl mzssl)
                      (if on?
                          mode
                          SSL_VERIFY_NONE)
                      #f)
      (let ([bytes #"racket"])
        (SSL_set_session_id_context (mzssl-ssl mzssl) bytes (bytes-length bytes)))
      (when on? (renegotiate who mzssl)))]))

(define (renegotiate who mzssl)
  (define (check-err thunk) 
    (let loop ()
      (define-values (v err estr) (save-errors (thunk) (mzssl-ssl mzssl)))
      (when (negative? v)
        (cond
         [(= err SSL_ERROR_WANT_READ)
          (let ([n (pump-input-once mzssl #f)])
            (if (eq? n 0)
                (let ([out-blocked? (pump-output mzssl)])
                  (sync (mzssl-i mzssl) 
                        (if out-blocked?
                            (mzssl-o mzssl) 
                            never-evt))
                  (loop))
                (loop)))]
         [(= err SSL_ERROR_WANT_WRITE)
          (if (pump-output-once mzssl #f #f)
              (loop)
              (begin
                (sync (mzssl-o mzssl))
                (loop)))]
         [else
          (error who "failed: ~a" estr)]))))
  (check-err (lambda () (SSL_renegotiate (mzssl-ssl mzssl))))
  (check-err (lambda () (SSL_do_handshake (mzssl-ssl mzssl))))
  (when (mzssl-server? mzssl)
    ;; Really demanding a negotiation from the server
    ;; side requires a hacky little dance
    (cond
     [SSLv23_client_method
      ;; OpenSSL 1.0 (could be replaced with 1.1 version?)
      (when (positive? (ssl_struct-server
                        (cast (mzssl-ssl mzssl) _pointer _ssl_struct-pointer)))
        (set-ssl_struct-state! (cast (mzssl-ssl mzssl) _pointer _ssl_struct-pointer)
                               SSL_ST_ACCEPT)
        (check-err (lambda () (SSL_do_handshake (mzssl-ssl mzssl)))))]
     [else
      ;; OpenSSL 1.1:
      ;; The thread
      ;;  https://groups.google.com/forum/#!topic/mailing.openssl.dev/Dzuwxgq19Ew
      ;; concludes that using SSL_peek with 0 is good enough to trigger renegotiation.
      ;; The peek might not actually return 0, but the pending-renegotiation state
      ;; should end.
      (check-err (lambda () 
                   (define v (SSL_peek (mzssl-ssl mzssl) (make-bytes 1) 0))
                   (if (and (negative? v)
                            (zero? (SSL_renegotiate_pending (mzssl-ssl mzssl))))
                       0
                       v)))])))

;; ----

(define (secure-client-context! ctx)
  ;; Load root certificates
  (ssl-load-default-verify-sources! ctx)
  ;; Require verification
  (ssl-set-verify! ctx #t)
  (ssl-set-verify-hostname! ctx #t)
  ;; No weak cipher suites; see discussion, patch at http://bugs.python.org/issue13636
  (ssl-set-ciphers! ctx "DEFAULT:!aNULL:!eNULL:!LOW:!EXPORT:!SSLv2")
  ;; Seal context so further changes cannot weaken it
  (ssl-seal-context! ctx)
  (void))

;; context-cache: (list (weak-box ssl-client-context) (listof path-string) nat) or #f
;; Cache for (ssl-secure-client-context) and (ssl-make-client-context 'secure) (w/o key, cert).
(define context-cache #f)

(define (ssl-secure-client-context)
  (let ([locs (ssl-default-verify-sources)])
    (define (reset)
      (let* ([now (current-seconds)]
             [ctx (ssl-make-client-context 'auto)])
        (secure-client-context! ctx)
        (set! context-cache (list (make-weak-box ctx) locs now))
        ctx))
    (let* ([cached context-cache]
           [c-wb (and cached (car cached))]
           [c-ctx (and c-wb (weak-box-value c-wb))]
           [c-locs (and cached (cadr cached))]
           [c-time (and cached (caddr cached))])
      (cond [c-ctx
             ;; May reuse only if locations haven't changed
             ;; FIXME: ideally, should also check that no file in locs has changed since
             ;;   c-time, but don't want to hit the filesystem so often
             (cond [(equal? locs c-locs) c-ctx]
                   [else (reset)])]
            [else (reset)]))))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SSL ports

(define (mzssl-release mzssl)
  ;; Lock must be held
  (set-mzssl-refcount! mzssl (sub1 (mzssl-refcount mzssl)))
  (when (zero? (mzssl-refcount mzssl))
    (SSL_free (mzssl-ssl mzssl))
    (when (mzssl-close-original? mzssl)
      (close-input-port (mzssl-i mzssl))
      (close-output-port (mzssl-o mzssl)))))

(define (pump-input-once mzssl need-progress?/out)
  (let ([buffer (mzssl-buffer mzssl)]
        [i (mzssl-i mzssl)]
        [r-bio (mzssl-r-bio mzssl)])
    (let ([n ((if (and need-progress?/out 
                 (not (output-port? need-progress?/out)))
            read-bytes-avail! 
            read-bytes-avail!*)
        buffer i)])
      (cond
       [(eof-object? n) 
        (BIO_set_mem_eof_return r-bio 0)
        eof]
       [(zero? n)
        (when need-progress?/out
          (sync need-progress?/out i))
        0]
       [else 
        (let ([m (BIO_write r-bio buffer n)])
          (unless (= m n)
            ((mzssl-error mzssl) 'pump-input-once "couldn't write all bytes to BIO!"))
          m)]))))

(define (pump-output-once mzssl need-progress? output-blocked-result)
  (let ([buffer (mzssl-buffer mzssl)]
        [pipe-r (mzssl-pipe-r mzssl)]
        [pipe-w (mzssl-pipe-w mzssl)]
        [o (mzssl-o mzssl)]
        [w-bio (mzssl-w-bio mzssl)])
    (let ([n (peek-bytes-avail!* buffer 0 #f pipe-r)])
      (if (zero? n)
          (let ([n (BIO_read w-bio buffer (bytes-length buffer))])
            (if (n . <= . 0)
          (begin
            (when need-progress?
              ((mzssl-error mzssl) 'pump-output-once "no output to pump!"))
            #f)
          (begin
            (write-bytes buffer pipe-w 0 n)
            (pump-output-once mzssl need-progress? output-blocked-result))))
          (let ([n ((if need-progress? write-bytes-avail write-bytes-avail*) buffer o 0 n)])
            (if (zero? n)
          output-blocked-result
          (begin
            (port-commit-peeked n (port-progress-evt pipe-r) always-evt pipe-r)
            #t)))))))

;; result is #t if there's more data to send out the
;;  underlying output port, but the port is full
(define (pump-output mzssl)
  (let ([v (pump-output-once mzssl #f 'blocked)])
    (if (eq? v 'blocked)
        #t
        (and v
             (pump-output mzssl)))))

(define (make-ssl-input-port mzssl)
  ;; If SSL_read produces NEED_READ or NEED_WRITE, then the next
  ;;  call to SSL_read must use the same arguments.
  ;; Use xfer-buffer so we have a consistent buffer to use with
  ;;  SSL_read across calls to the port's write function.
  (let-values ([(xfer-buffer) (make-bytes BUFFER-SIZE)]
         [(got-r got-w) (make-pipe)]
         [(must-read-len) #f])
    (make-input-port/read-to-peek
     (format "SSL ~a" (object-name (mzssl-i mzssl)))
     ;; read proc:
     (letrec ([do-read
         (lambda (buffer)
           (let ([len (or must-read-len (min (bytes-length xfer-buffer)
                                             (bytes-length buffer)))])
             (let-values ([(n err estr) (save-errors
                                               (SSL_read (mzssl-ssl mzssl) xfer-buffer len)
                                               (mzssl-ssl mzssl))])
               (if (n . >= . 1)
                   (begin
                     (set! must-read-len #f)
                     (if must-read-len
                         ;; If we were forced to try to read a certain amount,
                         ;; then we may have read too much for the immediate
                         ;; request.
                         (let ([orig-n (bytes-length buffer)])
                           (bytes-copy! buffer 0 xfer-buffer 0 (min n orig-n))
                           (when (n . > . orig-n)
                             (write-bytes buffer got-w orig-n n)))
                         (bytes-copy! buffer 0 xfer-buffer 0 n))
                     n)
                   (let ()
                     (cond
                      [(or (= err SSL_ERROR_ZERO_RETURN)
                           (and (= err SSL_ERROR_SYSCALL) (zero? n)))
                       ;; We hit the end-of-file
                       (set! must-read-len #f)
                       eof]
                      [(= err SSL_ERROR_WANT_READ)
                       (when enforce-retry?
                               (set! must-read-len len))
                       (let ([n (pump-input-once mzssl #f)])
                         (if (eq? n 0)
                             (let ([out-blocked? (pump-output mzssl)])
                                     (when enforce-retry?
                                       (set-mzssl-must-read! mzssl (make-semaphore)))
                               (wrap-evt (choice-evt
                                          (mzssl-i mzssl) 
                                          (if out-blocked?
                                              (mzssl-o mzssl) 
                                              never-evt))
                                         (lambda (x) 0)))
                             (do-read buffer)))]
                      [(= err SSL_ERROR_WANT_WRITE)
                             (when enforce-retry?
                               (set! must-read-len len))
                       (if (pump-output-once mzssl #f #f)
                           (do-read buffer)
                           (begin
                                   (when enforce-retry?
                                     (set-mzssl-must-read! mzssl (make-semaphore)))
                             (wrap-evt (mzssl-o mzssl) (lambda (x) 0))))]
                      [else
                             (set! must-read-len #f)
                       ((mzssl-error mzssl) 'read-bytes 
                              "SSL read failed ~a"
                              estr)]))))))]
        [top-read
         (lambda (buffer)
           (cond
            [(mzssl-flushing? mzssl)
             ;; Flush in progress; try again later:
             0]
            [(mzssl-must-write mzssl)
             => (lambda (sema)
                  (wrap-evt (semaphore-peek-evt sema) (lambda (x) 0)))]
            [(mzssl-r-closed? mzssl)
             0]
            [else
             (let ([sema (mzssl-must-read mzssl)])
               (when sema
                 (set-mzssl-must-read! mzssl #f)
                 (semaphore-post sema)))
             ;; First, try pipe for previously read data:
             (let ([n (read-bytes-avail!* buffer got-r)])
               (if (zero? n)
                   ;; Nothing already read, so use SSL_read:
                   (do-read buffer)
                   ;; Got previously read data:
                   n))]))]
        [lock-unavailable
         (lambda () (wrap-evt (semaphore-peek-evt (mzssl-lock mzssl))
                              (lambda (x) 0)))])
       (lambda (buffer)
         (call-with-semaphore
          (mzssl-lock mzssl)
          top-read
          lock-unavailable
          buffer)))
     ;; fast peek:
     #f
     ;; close proc:
     (lambda ()
       (call-with-semaphore
        (mzssl-lock mzssl)
        (lambda ()
          (unless (mzssl-r-closed? mzssl)
            (set-mzssl-r-closed?! mzssl #t)
            (mzssl-release mzssl))))))))

(define (flush-ssl mzssl enable-break?)
  ;; Make sure that this SSL connection has said everything that it
  ;; wants to say --- that is, move data from the SLL output to the
  ;; underlying output port. Depending on the transport, the other end
  ;; may be stuck trying to tell us something before it will listen, 
  ;; so we also have to read in any available information.
  (let loop ()
    (let ([v (pump-input-once mzssl #f)])
      (if (and (number? v) (positive? v))
          ;; Received some input, so start over
          (loop)
          ;; Try sending output
          (let ([v (pump-output-once mzssl #f 'blocked)])
            ;; If we sent something, continue tring in case there's more.
            ;; Further, if we blocked on the underlying output, then
            ;; wait until either input or output is ready:
            (when v
        (when (eq? v 'blocked)
          ((if enable-break? sync/enable-break sync) (mzssl-o mzssl) (mzssl-i mzssl)))
        (loop)))))))

(define (kernel-thread thunk)
  ;; Run with a custodian that is managed directly by the root custodian:
  (parameterize ([current-custodian (make-custodian-at-root)])
    (thread thunk)))

(define (make-ssl-output-port mzssl)
  ;; If SSL_write produces NEED_READ or NEED_WRITE, then the next
  ;;  call to SSL_write must use the same arguments.
  ;; Use xfer-buffer so we have a consistent buffer to use with
  ;;  SSL_write across calls to the port's write function.
  (let ([xfer-buffer (make-bytes BUFFER-SIZE)]
        [buffer-mode (or (file-stream-buffer-mode (mzssl-o mzssl)) 'bloack)]
        [flush-ch (make-channel)]
        [must-write-len #f])
    ;; This thread mkoves data from the SLL stream to the underlying
    ;; output port, because this port's write prodcue claims that the
    ;; data is flushed if it gets into the SSL stream. In other words,
    ;; this flushing thread is analogous to the OS's job of pushing
    ;; data from a socket through the actual network device. It therefore
    ;; runs with the highest possible custodian:
    (kernel-thread (lambda ()
               (let loop ()
                 (sync flush-ch)
                 (semaphore-wait (mzssl-lock mzssl))
                 (flush-ssl mzssl #f)
                 (semaphore-post (mzssl-flushing? mzssl))
                 (set-mzssl-flushing?! mzssl #f)
                 (semaphore-post (mzssl-lock mzssl))
                 (loop))))
    ;; Create the output port:
    (make-output-port
     (format "SSL ~a" (object-name (mzssl-o mzssl)))
     (mzssl-o mzssl)
     ;; write proc:
     (letrec ([do-write
         (lambda (len non-block? enable-break?)
           (let ([out-blocked? (pump-output mzssl)])
             (if (zero? len)
                 ;; Flush request; all data is in the SSL
                 ;;  stream, but make sure it's gone
                 ;;  through the ports:
                 (begin
                   (flush-ssl mzssl enable-break?)
                   0)
                 ;; Write request; even if blocking is ok, we treat
                 ;;  it as non-blocking and let Racket handle blocking
                 (let-values ([(n err estr) (save-errors (SSL_write (mzssl-ssl mzssl) xfer-buffer len)
                                                               (mzssl-ssl mzssl))])
                   (if (n . > . 0)
                       (begin
                         (set! must-write-len #f)
                         ;; Start flush as necessary:
                         (cond
                          [non-block?
                           ;; We can't block, so start the background thread
                           ;;  to flush from SSL to the underlying ports:
                           (set-mzssl-flushing?! mzssl (make-semaphore))
                           (channel-put flush-ch #t)]
                          [else
                           ;; We're allowed to block, and things seem to
                           ;;  work better if we, try to flush all the way
                           ;;  through (even though we're allowed to buffer):
                           (flush-ssl mzssl enable-break?)])
                         n)
                       (let ()
                         (cond
                          [(= err SSL_ERROR_WANT_READ)
                                 (when enforce-retry?
                                   (set! must-write-len len))
                           (let ([n (pump-input-once mzssl #f)])
                             (if (eq? n 0)
                                 (let ([out-blocked? (pump-output mzssl)])
                                         (when enforce-retry?
                                           (set-mzssl-must-write! mzssl (make-semaphore)))
                                   (wrap-evt (choice-evt
                                              (mzssl-i mzssl)
                                              (if out-blocked?
                                                  (mzssl-o mzssl)
                                                  never-evt))
                                             (lambda (x) #f)))
                                 (do-write len non-block? enable-break?)))]
                          [(= err SSL_ERROR_WANT_WRITE)
                                 (when enforce-retry?
                                   (set! must-write-len len))
                           (if (pump-output-once mzssl #f #f)
                               (do-write len non-block? enable-break?)
                                     (let ([n (pump-input-once mzssl #f)])
                                       (if (positive? n)
                                           (do-write len non-block? enable-break?)
                                           (begin
                                             (when enforce-retry?
                                               (set-mzssl-must-write! mzssl (make-semaphore)))
                                             (wrap-evt (mzssl-o mzssl) (lambda (x) #f))))))]
                          [else
                           (set! must-write-len #f)
                           ((mzssl-error mzssl) 'write-bytes 
                                  "SSL write failed ~a"
                                  estr)])))))))]
        [top-write
         (lambda (buffer s e non-block? enable-break?)
           (cond
            [(mzssl-flushing? mzssl)
             ;; Need to wait until flush done
             (if (= s e)
                 ;; Let the background flush finish:
                 (list (semaphore-peek-evt (mzssl-flushing? mzssl)))
                 ;; Try again later:
                 (wrap-evt always-evt (lambda (v) #f)))]
            [(mzssl-w-closed? mzssl)
             #f]
            [(mzssl-must-read mzssl)
             ;; Read pending, so wait until it's done:
             => (lambda (sema)
                  (wrap-evt (semaphore-peek-evt sema) (lambda (x) #f)))]
            [else
             ;; Normal write (since no flush is active or read pending):
             (let ([sema (mzssl-must-write mzssl)])
               (when sema
                 (set-mzssl-must-write! mzssl #f)
                 (semaphore-post sema)))
             (let ([len (min (- e s) (bytes-length xfer-buffer))])
               (if must-write-len
                   ;; Previous SSL_write result obligates certain output:
                   (begin
                     (unless (and (len . >= . must-write-len)
                                  (bytes=? (subbytes xfer-buffer 0 must-write-len)
                                           (subbytes buffer s (+ s must-write-len))))
                       ((mzssl-error mzssl) 'write-bytes 
                              "SSL output request: ~e different from previous unsatisfied request: ~e"
                              (subbytes buffer s e)
                              (subbytes xfer-buffer 0 must-write-len)))
                     (do-write must-write-len non-block? enable-break?))
                   ;; No previous write obligation:
                   (begin
                     (bytes-copy! xfer-buffer 0 buffer s (+ s len))
                     (do-write len non-block? enable-break?))))]))]
        [lock-unavailable
         (lambda () (wrap-evt (semaphore-peek-evt (mzssl-lock mzssl))
                              (lambda (x) #f)))])
       (lambda (buffer s e non-block? enable-break?)
         (let ([v (call-with-semaphore
             (mzssl-lock mzssl)
             top-write
             lock-unavailable
             buffer s e non-block? enable-break?)])
           (if (pair? v)
         (begin
           ;; Wait on background flush to implement requested flush
           (sync (car v))
           0)
         v))))
     ;; close proc:
     (letrec ([do-close
         (lambda ()
           (cond
            [(mzssl-flushing? mzssl)
             (semaphore-peek-evt (mzssl-flushing? mzssl))]
            [(mzssl-w-closed? mzssl)
             #f]
            [else
             ;; issue shutdown (i.e., EOF on read end)
             (when (mzssl-shutdown-on-close? mzssl)
               (let loop ([cnt 0])
                 (let ()
                         (flush-ssl mzssl #f)
                   (let-values ([(n err estr) (save-errors (SSL_shutdown (mzssl-ssl mzssl))
                                                                 (mzssl-ssl mzssl))])
                           
                           (if (= n 1)
                               (flush-ssl mzssl #f)
                               (cond
                                [(= err SSL_ERROR_WANT_READ)
                                 (let ([out-blocked? (pump-output mzssl)])
                                   (pump-input-once mzssl (if out-blocked? (mzssl-o mzssl) #t)))
                                 (loop cnt)]
                                [(= err SSL_ERROR_WANT_WRITE)
                                 (pump-output-once mzssl #t #f)
                                 (loop cnt)]
                                [else
                                 (if (= n 0)
                                     ;; When 0 is returned, a shutdown depends on
                                     ;; input from the peer. If we've already tried twice,
                                     ;; wait for some input and try again.
                                     (begin
                                       (when (cnt . >= . 2)
                                         (pump-input-once mzssl #t))
                                       (loop (add1 cnt)))
                                     ((mzssl-error mzssl) 'read-bytes 
                                      "SSL shutdown failed ~a"
                                      estr))]))))))
             (set-mzssl-w-closed?! mzssl #t)
             (mzssl-release mzssl)
             #f]))]
        [close-loop
         (lambda ()
           (let ([v (call-with-semaphore
                     (mzssl-lock mzssl)
                     do-close)])
             (if v
                 (begin
                   ;; Wait for background flush to finish:
                   (sync v)
                   (close-loop))
                 v)))])
       (lambda ()
         (close-loop)))
     ;; Unimplemented port methods:
     #f #f #f #f
     void 1
     ;; Buffer mode proc:
     (case-lambda
      [() buffer-mode]
      [(mode) (set! buffer-mode mode)]))))

(define (ports->ssl-ports i o 
                          #:context [context #f]
                          #:encrypt [encrypt default-encrypt]
                          #:mode [mode 'connect]
                          #:close-original? [close-original? #f]
                          #:shutdown-on-close? [shutdown-on-close? #f]
                          #:error/ssl [error/ssl error]
                          #:hostname [hostname #f])
  (wrap-ports 'port->ssl-ports i o (or context encrypt) mode
              close-original? shutdown-on-close? error/ssl
              hostname))

(define (create-ssl who context-or-encrypt-method connect/accept error/ssl)
  (define connect?
    (case connect/accept
      [(connect) #t]
      [(accept) #f]
      [else (error who "internal error: bad connect/accept: ~e" connect/accept)]))
  (unless (or (symbol? context-or-encrypt-method)
              (if connect?
                  (ssl-client-context? context-or-encrypt-method)
                  (ssl-server-context? context-or-encrypt-method)))
    (error who
           "'~a mode requires a ~a context, given: ~e"
           (if connect? 'connect 'accept)
           (if connect? "client" "server")
           context-or-encrypt-method))
  (atomically ;; connect functions to subsequent check-valid (ie, ERR_get_error)
   (let ([ctx (get-context who context-or-encrypt-method connect?)])
     (check-valid ctx who "context creation")
     (with-failure
      (lambda () (when (and ctx
                       (need-ctx-free? context-or-encrypt-method))
                   (SSL_CTX_free ctx)))
      (let ([r-bio (BIO_new (BIO_s_mem))]
            [w-bio (BIO_new (BIO_s_mem))]
            [free-bio? #t])
        (with-failure
         (lambda () (when free-bio?
                      (BIO_free r-bio)
                      (BIO_free w-bio)))
         (let ([ssl (SSL_new ctx)])
           (check-valid ssl who "ssl setup")
           ;; ssl has a ref count on ctx, so release:
           (when (need-ctx-free? context-or-encrypt-method)
             (SSL_CTX_free ctx)
             (set! ctx #f))
           (with-failure
            (lambda () (SSL_free ssl))
            (SSL_set_bio ssl r-bio w-bio)
            ;; ssl has r-bio & w-bio (no ref count?), so drop it:
            (set! free-bio? #f)
            (values ssl r-bio w-bio connect?)))))))))

(define (wrap-ports who i o context-or-encrypt-method connect/accept
                    close? shutdown-on-close? error/ssl
                    hostname)
  ;; Create the SSL connection:
  (let-values ([(ssl r-bio w-bio connect?)
          (create-ssl who context-or-encrypt-method connect/accept error/ssl)]
               [(verify-hostname?)
                (cond [(ssl-context? context-or-encrypt-method)
                       (ssl-context-verify-hostname? context-or-encrypt-method)]
                      [else #f])])
    (when (string? hostname)
      (SSL_ctrl/bytes ssl SSL_CTRL_SET_TLSEXT_HOSTNAME
                      TLSEXT_NAMETYPE_host_name (string->bytes/latin-1 hostname)))

    ;; connect/accept:
    (let-values ([(buffer) (make-bytes BUFFER-SIZE)]
           [(pipe-r pipe-w) (make-pipe)])
      (let ([mzssl (make-mzssl ssl i o r-bio w-bio pipe-r pipe-w 
                         buffer (make-semaphore 1) 
                         #f #f
                         #f #f #f 2 
                         close? shutdown-on-close?
                               error/ssl
                               (eq? connect/accept 'accept))])
        (let loop ()
          (let-values ([(status err estr) (save-errors (if connect?
                                                           (SSL_connect ssl)
                                                           (SSL_accept ssl))
                                                       ssl)])
            (let ([out-blocked? (pump-output mzssl)])
        (when (status . < . 1)
          (let ()
            (cond
             [(= err SSL_ERROR_WANT_READ)
              (let ([n (pump-input-once mzssl (if out-blocked? o #t))])
                (when (eof-object? n)
                  (error/ssl who "~a failed (input terminated prematurely)"
                                   (if connect? "connect" "accept"))))
              (loop)]
             [(= err SSL_ERROR_WANT_WRITE)
              (pump-output-once mzssl #t #f)
              (loop)]
             [else
              (error/ssl who "~a failed ~a"
                               (if connect? "connect" "accept")
                               estr)]))))))
        (when verify-hostname?
          (unless hostname
            (error/ssl who "~a failed (hostname not provided for verification)"
                       (if connect? "connect" "accept")))
          (unless (hostname-in-cert? hostname (SSL_get_peer_certificate ssl))
            (error/ssl who "~a failed (certificate not valid for hostname)"
                       (if connect? "connect" "accept"))))
        ;; Connection complete; make ports
        (values (register (make-ssl-input-port mzssl) mzssl #t)
          (register (make-ssl-output-port mzssl) mzssl #f))))))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SSL port registry

(define ssl-ports (make-weak-hasheq))

(define (register port mzssl input?)
  (hash-set! ssl-ports port (make-ephemeron port (cons mzssl input?)))
  port)

(define (lookup who port)
  (let ([v (hash-ref ssl-ports port #f)])
    (unless v
      (error who "internal error: not an SSL port or listener: ~e" port))
    (let ([p (ephemeron-value v)])
      (values (car p) (cdr p)))))

(define (ssl-addresses p [port-numbers? #f])
  (let-values ([(mzssl input?) (lookup 'ssl-addresses p)])
    (define port
      (if (eq? 'listener input?)
          (ssl-listener-l mzssl)
          (if input? (mzssl-i mzssl) (mzssl-o mzssl))))
    (cond [(tcp-port? port) (tcp-addresses port port-numbers?)]
          [else (error 'ssl-addresses "not connected to TCP port")])))

(define (ssl-abandon-port p)
  (let-values ([(mzssl input?) (lookup 'ssl-abandon-port p)])
    (cond
     [(output-port? p)
      (set-mzssl-shutdown-on-close?! mzssl #f)
      ;; Call close-output-port to flush, shutdown, and decrement mzssl refcount.
      (close-output-port p)]
     [else
      (close-input-port p)])))

(define (ssl-peer-verified? p)
  (let-values ([(mzssl input?) (lookup 'ssl-peer-verified? p)])
    (and (eq? X509_V_OK (SSL_get_verify_result (mzssl-ssl mzssl)))
         (SSL_get_peer_certificate (mzssl-ssl mzssl))
         #t)))

(define (ssl-peer-subject-name p)
  (let ([cert (ssl-port->cert 'ssl-peer-subject-name p)])
    (if cert
        (let ([bytes (make-bytes 1024 0)])
          (X509_NAME_oneline (X509_get_subject_name cert) bytes (bytes-length bytes)))
        #f)))

(define (ssl-peer-issuer-name p)
  (let ([cert (ssl-port->cert 'ssl-peer-subject-name p)])
    (if cert
        (let ([bytes (make-bytes 1024 0)])
          (X509_NAME_oneline (X509_get_issuer_name cert) bytes (bytes-length bytes)))
        #f)))

;; ssl-peer-certificate-hostnames : ssl-port -> (listof string)
(define (ssl-peer-certificate-hostnames p)
  (let ([cert (ssl-port->cert 'ssl-peer-certificate-hostnames p)])
    (if cert (cert->names cert) null)))

;; ssl-peer-check-hostname : ssl-port string -> boolean
(define (ssl-peer-check-hostname p hostname)
  (let ([cert (ssl-port->cert 'ssl-peer-check-hostname p)])
    (hostname-in-cert? hostname cert)))

;; ssl-port->cert : symbol ssl-port -> Cert/#f
(define (ssl-port->cert who p)
  (let-values ([(mzssl _input?) (lookup who p)])
    (SSL_get_peer_certificate (mzssl-ssl mzssl))))

;; hostname-in-cert? : string Cert -> boolean
(define (hostname-in-cert? hostname cert)
  (for/or ([cert-hostname (in-list (cert->names cert))])
    (check-hostname hostname cert-hostname)))

(define (cert->names cert)
  ;; RFC 2818 (section 3.1) says use subjectAltName dNSName extensions
  ;; if present, else use final commonName entry.
  (let ([names (cert->altnames cert)])
    (cond [(pair? names) names]
          [else (let ([name (cert->name cert)])
                  (if name (list name) null))])))

(define (cert->name cert)
  ;; Returns commonName DNS name if exists, #f otherwise.
  (let* ([name (X509_get_subject_name cert)]
         [last-cn-index
          (let loop ([i -1])
            (let ([next (X509_NAME_get_index_by_NID name NID_commonName i)])
              (cond [(>= next 0) (loop next)]
                    [else i])))])
    (cond [(< last-cn-index 0) #f]
          [else
           (let* ([entry (X509_NAME_get_entry name last-cn-index)]
                  [asn1str (X509_NAME_ENTRY_get_data entry)])
             (asn1string->bytes asn1str))])))

(define (asn1string->bytes asn1str)
  (let* ([len (ASN1_STRING_length asn1str)]
         [data (ASN1_STRING_data asn1str)]
         [buf (make-bytes len 0)])
    (memcpy buf data len)
    ;; FIXME: detect UTF-8 strings?
    (bytes->string/latin-1 buf)))

(define (cert->altnames cert)
  ;; Returns list of DNS names in subjectAltName extension
  ;; FIXME: also return IP addresses?
  ;; Reference: curl-7.28.0/lib/ssluse.c verifyhost()
  ;;  from http://www.mail-archive.com/openssl-users@openssl.org/msg39142.html
  (let* ([namestack (X509_get_ext_d2i cert NID_subject_alt_name #f #f)]
         [names
          (reverse
           (for/fold ([acc null])
               ([i (in-range (if namestack (sk_num namestack) 0))])
             (let ([gn (sk_GENERAL_NAME_value namestack i)])
               (cond [(= (GENERAL_NAME-type gn) GEN_DNS)
                      (let* ([asn1str (GENERAL_NAME-d gn)])
                        (cons (asn1string->bytes asn1str) acc))]
                     [else acc]))))])
    (when namestack (sk_pop_free namestack GENERAL_NAME_free))
    names))

(define (check-hostname cx-name cert-name-pattern)
  (let* ([cx-parts (string-split cx-name "." #:trim? #f)]
         [cert-parts (string-split cert-name-pattern "." #:trim? #f)])
    (and (equal? (length cx-parts)
                 (length cert-parts))
         (andmap check-hostname-part cx-parts cert-parts))))

(define (check-hostname-part cx-part cert-part)
  (cond [(equal? cert-part "*")
         #t]
        [(for/or ([c (in-string cert-part)]) (eqv? c #\*))
         (regexp-match? (glob->regexp cert-part) cx-part)]
        [else (string-ci=? cx-part cert-part)]))

(define (glob->regexp glob)
  (let* ([lit-parts (string-split glob #rx"[*]" #:trim? #f)]
         [lit-rxs (for/list ([part (in-list lit-parts)]) (regexp-quote part #f))])
    (regexp (string-join lit-rxs ".*"))))

(define (ssl-port? v)
  (and (hash-ref ssl-ports v #f) #t))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SSL listen

(define (ssl-listen port-k
                    [queue-k 5] [reuse? #f] [hostname-or-#f #f]
                    [protocol-symbol-or-context default-encrypt])
  (let* ([ctx (if (ssl-server-context? protocol-symbol-or-context)
               protocol-symbol-or-context
               (make-context 'ssl-listen protocol-symbol-or-context #f #f #f))]
        [l (tcp-listen port-k queue-k reuse? hostname-or-#f)]
        [ssl-l (make-ssl-listener l ctx)])
    (register ssl-l ssl-l 'listener)))

(define (ssl-close l)
  (tcp-close (ssl-listener-l l)))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SSL accept

(define (do-ssl-accept who tcp-accept ssl-listener)
  (let-values ([(i o) (tcp-accept (ssl-listener-l ssl-listener))])
    ;; Obviously, there's a race condition between accepting the
    ;; connections and installing the exception handler below. However,
    ;; if breaks are enabled, then i and o could get lost between
    ;; the time that tcp-accept returns and `i' and `o' are bound,
    ;; anyway. So we can assume that breaks are enabled without loss
    ;; of (additional) resources.
    (with-handlers ([void (lambda (exn)
                            (close-input-port i)
                            (close-output-port o)
                            (raise exn))])
      (wrap-ports who i o (ssl-listener-mzctx ssl-listener) 'accept #t #f error/network #f))))

(define (ssl-accept ssl-listener)
  (do-ssl-accept 'ssl-accept tcp-accept ssl-listener))

(define (ssl-accept/enable-break ssl-listener)
  (do-ssl-accept 'ssl-accept/enable-break tcp-accept/enable-break ssl-listener))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SSL connect

(define (do-ssl-connect who tcp-connect hostname port-k client-context-or-protocol-symbol)
  (let-values ([(i o) (tcp-connect hostname port-k)])
    ;; See do-ssl-accept for note on race condition here:
    (with-handlers ([void (lambda (exn)
                            (close-input-port i)
                            (close-output-port o)
                            (raise exn))])
      (wrap-ports who i o client-context-or-protocol-symbol 'connect #t #f error/network
                  hostname))))

(define (ssl-connect hostname port-k
                     [client-context-or-protocol-symbol default-encrypt])
  (do-ssl-connect 'ssl-connect
                  tcp-connect
                  hostname
                  port-k
                  client-context-or-protocol-symbol))

(define (ssl-connect/enable-break hostname port-k
                                  [client-context-or-protocol-symbol default-encrypt])
  (do-ssl-connect 'ssl-connect/enable-break
                  tcp-connect/enable-break
                  hostname
                  port-k
                  client-context-or-protocol-symbol))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Initialization

(define ssl-available? (and libssl #t))


(when ssl-available?
  ;; Make sure only one place tries to initialize OpenSSL,
  ;; and wait in case some other place is currently initializing
  ;; it.
  (begin
    (start-atomic)
    (let* ([done (ptr-add #f 1)]
           [v (register-process-global #"OpenSSL-support-initializing" done)])
      (if v
          ;; Some other place is initializing:
          (begin
            (end-atomic)
            (let loop ()
              (unless (register-process-global #"OpenSSL-support-initialized" #f)
                (sleep 0.01) ;; busy wait! --- this should be rare
                (loop))))
          ;; This place must initialize:
          (begin
            (SSL_library_init)
            (SSL_load_error_strings)
            (register-process-global #"OpenSSL-support-initialized" done)
            (end-atomic))))))
