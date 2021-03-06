;;; Bootstrap declarations

;; The bootstrap compiler will assume that all undeclared names refer
;; to functions, so we have to explicitly declare the variables that
;; are used before they are defined.

; (declare-variables foo bar)

(define (bootstrap-phase)
  'running)

;;; Basic Suo syntax

(define (macroexpand1 form)
  (if (and (pair? form) (pathname? (car form)))
      (let ((transformer (macro-lookup (car form))))
	(if transformer
	    (apply transformer (cdr form))
	    form))
      form))

(define (macroexpand form)
  (let ((exp (macroexpand1 form)))
    (if (eq? exp form)
	form
	(macroexpand exp))))

(define (expand-body body)
  (let loop ((defs '())
	     (rest body))
    (let ((first (macroexpand (car rest))))
      (cond ((and (pair? first) (or (eq? (car first) :define)
				    (eq? (car first) :define-function)))
	     (loop (cons first defs) (cdr rest)))
	    ((and (pair? first) (eq? (car first) :begin))
	     (loop defs (append (cdr first) (cdr rest))))
	    ((null? defs)
	     (cons first (cdr rest)))
	    (else
	     (let ((vars (map cadr defs))
		   (vals (map caddr defs)))
	       (list `(letrec ,(map list vars vals)
			,@(cons first (cdr rest))))))))))

;; Traditional quaisquote is wierd, mostly when being nested.  This is
;; from Alan Bawden, "Quasiquotation in Lisp", Appendix B.

(define (qq-expand x depth)
  (if (pair? x)
      (case (car x)
	((quasiquote)
	 ;; Guile can't seem to handle a 'quasiquote' symbol in a
	 ;; quasiquote expression; thus we use long hand here.
	 (list 'cons ''quasiquote
	       (qq-expand (cdr x) (+ depth 1))))
	((unquote unquote-splicing)
	 (cond ((> depth 0)
		`(cons ',(car x)
		       ,(qq-expand (cdr x) (- depth 1))))
	       ((and (eq? 'unquote (car x))
		     (not (null? (cdr x)))
		     (null? (cddr x)))
		(cadr x))
	       (else
		(error "illegal"))))
	(else
	 `(append ,(qq-expand-list (car x) depth)
		  ,(qq-expand (cdr x) depth))))
      `',x))

(define (qq-expand-list x depth)
  (if (pair? x)
      (case (car x)
	((quasiquote)
	 ;; Guile can't seem to handle a 'quasiquote' symbol in a
	 ;; quasiquote expression; thus we use long hand here.
	 (list 'list (list 'cons ''quasiquote
			   (qq-expand (cdr x) (+ depth 1)))))
	((unquote unquote-splicing)
	 (cond ((> depth 0)
		`(list (cons ',(car x)
			     ,(qq-expand (cdr x) (- depth 1)))))
	       ((eq? 'unquote (car x))
		`(list . ,(cdr x)))
	       (else
		`(append . ,(cdr x)))))
	(else
	 `(list (append ,(qq-expand-list (car x) depth)
			,(qq-expand (cdr x) depth)))))
      `'(,x)))

(define (lambda-transformer args body)
  (cons* :lambda args (expand-body body)))
  
(define-macro (lambda args . body)
  (lambda-transformer args body))

(define-macro (lambda-with-setter l s)
  `(let ((l (lambda ,@l))
	 (s (lambda ,@s)))
     (set! (setter l) s)
     l))

(define-macro (quote val)
  (list :quote val))

(define-macro (quasiquote form)
  (qq-expand form 0))

(define-macro (begin . body)
  `(:begin ,@body))

(define-macro (if cond then . else)
  (if (null? else)
      `(if ,cond ,then (begin))
      `(:primitive if-eq? () (,cond #f) (,(car else) ,then))))

(define-macro (define head . body)
  (if (pair? head)
;;    `(define-function ,(car head) (lambda ,(cdr head) ,@body))
      `(define-function ,(car head) (lambda ,(cdr head)
				      (primop syscall 0
					      ,(string-bytes
						(symbol->string (car head))))
				      (let ()
					,@body)))
      `(:define ,head ,(car body))))

(define-macro (define-function name . exprs)
  `(:define-function ,name ,@exprs))

(define-macro (define-record-type name expr)
  `(:define-record-type ,name ,expr))

(define-macro (define-macro head . body)
  (if (pair? head)
      `(define-macro ,(car head) (lambda ,(cdr head) ,@body))
      `(:define-macro ,head ,(car body))))

(define-macro (let first . rest)
  (if (symbol? first)
      (let ((name first)
	    (bindings (car rest))
	    (body (cdr rest)))
	`(letrec ((,name (lambda ,(map car bindings) ,@body)))
	   (,name ,@(map cadr bindings))))
      `((lambda ,(map car first) ,@rest) ,@(map cadr first))))

(define-macro (let* bindings . body)
  (if (null? bindings)
      `(let ()
	 ,@body)
      `(let (,(car bindings))
	 (let* ,(cdr bindings)
	   ,@body))))

(define (identity obj) obj)

(define-macro (cond . clauses)
  (if (null? clauses)
      `(quote ,(if #f #f))
      (let* ((clause (car clauses))
	     (test (car clause)))
	(if (eq? (cadr clause) '=>)
	    (let ((tmp (gensym)))
	      `(let ((,tmp ,test))
		 (if ,tmp
		     (,(caddr clause) ,tmp)
		     (cond ,@(cdr clauses)))))
	    (if (eq? test 'else)
		`(begin ,@(cdr clause))
		`(if ,test
		     (begin ,@(cdr clause))
		     (cond ,@(cdr clauses))))))))

(define-macro (case key . clauses)
  (let ((tmp (gensym)))
    `(let ((,tmp ,key))
       (cond ,@(map (lambda (clause)
		      (if (eq? (car clause) 'else)
			  clause
			  `((memv ,tmp ',(car clause)) ,@(cdr clause))))
		    clauses)))))

(define-macro (and=> test proc)
  (let ((tmp (gensym)))
    `(let ((,tmp ,test))
       (and ,tmp (,proc ,tmp)))))

(define-macro (set! place val)
  (if (pair? place)
      `((setter ,(car place)) ,val ,@(cdr place))
      `(:set ,place ,val)))

(define-macro (letrec bindings . body)
  (let ((vars (map car bindings))
	(inits (map cadr bindings))
	(unspec (if #f #f)))
    `(let ,(map (lambda (v) `(,v ',unspec)) vars)
       ,@(map (lambda (v i)
		`(set! ,v ,i))
	      vars inits)
       (let () ,@body))))

(define-macro (do specs term . body)
  (let* ((vars (map car specs))
	 (inits (map cadr specs))
	 (steps (map (lambda (s v) (if (null? (cddr s)) v (caddr s)))
		     specs vars))
	 (test (car term))
	 (term-body (cdr term))
	 (loop (gensym)))
    `(letrec ((,loop (lambda ,vars
		       (if ,test
			   (begin ,@term-body)
			   (begin ,@body
				  (,loop ,@steps))))))
       (,loop ,@inits))))

(define-macro (and . args)
  (cond ((null? args)
	 #t)
	((null? (cdr args))
	 (car args))
	(else
	 `(if ,(car args)
	      (and ,@(cdr args))
	      #f))))

(define-macro (or . args)
  (cond ((null? args)
	 #f)
	((null? (cdr args))
	 (car args))
	(else
	 (let ((tmp (gensym)))
	   `(let ((,tmp ,(car args)))
	      (if ,tmp
		  ,tmp
		  (or ,@(cdr args))))))))

(define-macro (primif cond then else)
  `(:primitive ,(car cond) () ,(cdr cond) (,then ,else)))

(define-macro (primop op . args)
  `(:primitive ,op (res) ,args (res)))

;;; Error handling

(define (error:not-a-closure thing)
  (error "not a closure: " thing))

(define (error:wrong-num-args)
  (error "wrong number of arguments"))

(define (set-wrong-num-args-hook)
  (primop syscall 9 -6 error:wrong-num-args))

(define (error:wrong-type val)
  (error "wrong type: " val))

(define (error:out-of-range val)
  (error "out of range: " val))

(define (error:overflow)
  (error "overflow"))

(define (display-error msg rest)
  (display "ERROR: ")
  (display msg)
  (for-each (lambda (r)
	      (display r)
	      (display " "))
	    rest)
  (newline))
  
(define handling-error #f)

(define (last-straw-error-handler msg rest)
  (if handling-error
      (sys:panic)
      (begin
	(set! handling-error #t)
	(display-error msg rest)
	(sys:panic))))

(define error-handlers (make-parameter '()))

(define (error msg . rest)
  (if (null? (error-handlers))
      (last-straw-error-handler msg rest)
      (let ((handler (car (error-handlers))))
	(error-handlers (cdr (error-handlers)))
	(handler msg rest))))

(define (with-error-handler handler thunk)
  (call-p error-handlers (cons handler (error-handlers)) thunk))

;;; Debugging

(define (pk . args)
  (display ";;; ")
  (for-each (lambda (a) (write a) (display " ")) args)
  (newline)
  (car (last-pair args)))

(define-macro (assert form)
  `(or ,form
       (error "assertion failed: " ',form)))

;;; Testing and booleans

(define (eq? a b)
  (primif (if-eq? a b) #t #f))

(define (eqv? a b)
  (eq? a b))

(define (not x)
  (if x #f #t))

;;; Pairs

(define (cons a b)
  (primop cons a b))

(define (pair? a)
  (primif (if-pair? a) #t #f))

(define (car a)
  (if (pair? a)
      (primop car a)
      (error:wrong-type a)))

(define (cdr a)
  (if (pair? a)
      (primop cdr a)
      (error:wrong-type a)))

(define (set-car! a val)
  (if (pair? a)
      (primop set-car a val)
      (error:wrong-type a)))

(define (set-cdr! a val)
  (if (pair? a)
      (primop set-cdr a val)
      (error:wrong-type a)))

(define (cadr a)
  (car (cdr a)))

(define (cddr a)
  (cdr (cdr a)))

(define (caar a)
  (car (car a)))

(define (cdar a)
  (cdr (car a)))

(define (caddr a)
  (car (cdr (cdr a))))

(define (cdddr a)
  (cdr (cdr (cdr a))))

(define (cadddr a)
  (car (cdddr a)))

;;; Lists

(define (list . elts)
  elts)

(define (cons* first . rest)
  (if (null? rest)
      first
      (cons first (apply cons* rest))))

(define (length lst)
  (if (null? lst)
      0
      (+ 1 (length (cdr lst)))))

(define (null? lst)
  (eq? lst '()))

(define (reduce f i l)
  (if (pair? l)
      (f (car l) (reduce f i (cdr l)))
      i))

(define (any pred lst)
  (if (null? lst)
      #f
      (or (pred (car lst))
	  (any pred (cdr lst)))))

(define (map1 func lst)
  (if (null? lst)
      '()
      (cons (func (car lst)) (map1 func (cdr lst)))))

(define (map func . lsts)
  (if (any null? lsts)
      '()
      (cons (apply func (map1 car lsts)) (apply map func (map1 cdr lsts)))))

(define (for-each func . lists)
  (if (not (any null? lists))
      (begin
	(apply func (map1 car lists))
	(apply for-each func (map1 cdr lists)))))

(define (or-map func lst)
  (if (null? lst)
      #f
      (let ((val (func (car lst))))
	(or val
	    (or-map func (cdr lst))))))
  
(define (reverse-with-tail list tail)
  (if (null? list)
      tail
      (reverse-with-tail (cdr list) (cons (car list) tail))))

(define (reverse list)
  (reverse-with-tail list '()))

(define (last-pair list)
  (if (null? (cdr list))
      list
      (last-pair (cdr list))))

(define (append . lists)
  (cond ((null? lists)
	 '())
	((null? (cdr lists))
	 (car lists))
	(else
	 (list-copy-with-tail (car lists)
			      (apply append (cdr lists))))))

(define (member elt lst)
  (cond ((null? lst)
	 #f)
	((equal? elt (car lst))
	 #t)
	(else
	 (member elt (cdr lst)))))

(define (memv elt lst)
  (cond ((null? lst)
	 #f)
	((eqv? elt (car lst))
	 #t)
	(else
	 (memv elt (cdr lst)))))

(define (memq elt lst)
  (cond ((null? lst)
	 #f)
	((eq? elt (car lst))
	 #t)
	(else
	 (memq elt (cdr lst)))))

(define (delq1 elt lst)
  (cond ((null? lst)
	 lst)
	((eq? elt (car lst))
	 (cdr lst))
	(else
	 (cons (car lst) (delq1 elt (cdr lst))))))

(define (list-copy lst)
  (list-copy-with-tail lst '()))

(define (list-copy-with-tail lst tail)
  (if (null? lst)
      tail
      (cons (car lst) (list-copy-with-tail (cdr lst) tail))))

(define (dotted-list? lst)
  (cond ((pair? lst)
	 (dotted-list? (cdr lst)))
	(else
	 (not (null? lst)))))

(define (dotted-list-copy lst)
  (cond ((pair? lst)
	 (cons (car lst) (dotted-list-copy (cdr lst))))
	(else
	 lst)))

(define (dotted-list-length lst)
  (cond ((pair? lst)
	 (1+ (dotted-list-length (cdr lst))))
	(else
	 0)))

(define (flatten-dotted-list lst)
  (cond ((pair? lst)
	 (cons (car lst) (flatten-dotted-list (cdr lst))))
	((null? lst)
	 '())
	(else
	 (list lst))))

(define (list-index lst obj)
  (let loop ((lst lst)
	     (i 0))
    (cond ((null? lst)
	   #f)
	  ((eq? (car lst) obj)
	   i)
	  (else
	   (loop (cdr lst) (1+ i))))))

(define (list-ref lst i)
  (if (zero? i)
      (car lst)
      (list-ref (cdr lst) (1- i))))

(define (list-head lst i)
  (if (or (zero? i) (null? lst))
      '()
      (cons (car lst) (list-head (cdr lst) (1- i)))))

(define (list-tail lst i)
  (if (zero? i)
      lst
      (list-tail (cdr lst) (1- i))))

(define (filter pred lst)
  (cond ((null? lst)
	 lst)
	((pred (car lst))
	 (cons (car lst) (filter pred (cdr lst))))
	(else
	 (filter pred (cdr lst)))))

;;; Association lists

(define (acons key val alist)
  (cons (cons key val) alist))

(define (assq key alist)
  (cond ((null? alist)
	 #f)
	((eq? key (car (car alist)))
	 (car alist))
	(else
	 (assq key (cdr alist)))))

(define (assq-ref alist key)
  (and=> (assq key alist) cdr))

(define (assq-del alist key)
  (cond ((null? alist)
	 '())
	((eq? key (car (car alist)))
	 (cdr alist))
	(else
	 (cons (car alist)
	       (assq-del (cdr alist) key)))))

(define (assoc key alist)
  (cond ((null? alist)
	 #f)
	((equal? key (car (car alist)))
	 (car alist))
	(else
	 (assoc key (cdr alist)))))

(define (assoc-ref alist key)
  (and=> (assoc key alist) cdr))

;;; Lists as sets

(define (set-difference l1 l2)
  "Return elements from list L1 that are not in list L2."
  (let loop ((l1 l1) (result '()))
    (cond ((null? l1) (reverse result))
	  ((memv (car l1) l2) (loop (cdr l1) result))
	  (else (loop (cdr l1) (cons (car l1) result))))))

(define (adjoin e l)
  "Return list L, possibly with element E added if it is not already in L."
  (if (memq e l) l (cons e l)))

(define (union l1 l2)
  "Return a new list that is the union of L1 and L2.
Elements that occur in both lists occur only once in
the result list."
  (cond ((null? l1) l2)
	((null? l2) l1)
	(else (union (cdr l1) (adjoin (car l1) l2)))))

(define (intersection l1 l2)
  "Return a new list that is the intersection of L1 and L2.
Only elements that occur in both lists occur in the result list."
  (if (null? l2) l2
      (let loop ((l1 l1) (result '()))
	(cond ((null? l1) (reverse result))
	      ((memv (car l1) l2) (loop (cdr l1) (cons (car l1) result)))
	      (else (loop (cdr l1) result))))))

;;; Byte vectors

(define (bytevec? val)
  (primif (if-bytevec? val) #t #f))

(define (make-bytevec n)
  (if (fixnum? n)
      (primop make-bytevec n)
      (error:wrong-type n)))

(define (bytevec-subvector v start end)
  (let ((s (make-bytevec (- end start))))
    (do ((i start (1+ i)))
	((= i end))
      (bytevec-set-u8! s (- i start) (bytevec-ref-u8 v i)))
    s))

(define (bytevec-length-8 bv)
  (if (bytevec? bv)
      (primop bytevec-length-8 bv)
      (error:wrong-type bv)))

(define (bytevec-ref-u8 bv i)
  (if (and (<= 0 i) (< i (bytevec-length-8 bv)))
      (primop bytevec-ref-u8 bv i)
      (error:out-of-range i)))

(define (bytevec-set-u8! bv i val)
  (if (and (<= 0 i) (< i (bytevec-length-8 bv)))
      (if (and (<= 0 val) (< val #x100))
	  (primop bytevec-set-u8 bv i val)
	  (error:out-of-range val))
      (error:out-of-range i)))

(define (bytevec-length-16 bv)
  (if (bytevec? bv)
      (primop bytevec-length-16 bv)
      (error:wrong-type bv)))

(define (bytevec-ref-u16 bv i)
  (if (and (<= 0 i) (< i (bytevec-length-16 bv)))
      (primop bytevec-ref-u16 bv i)
      (error:out-of-range i)))

(define (bytevec-set-u16! bv i val)
  (if (and (<= 0 i) (< i (bytevec-length-16 bv)))
      (if (and (<= 0 val) (< val #x10000))
	  (primop bytevec-set-u16 bv i val)
	  (error:out-of-range val))
      (error:out-of-range i)))

(define (bytevec-u16 . vals)
  (let* ((n (length vals))
	 (v (make-bytevec (* 2 n))))
    (do ((i 0 (1+ i))
	 (vals vals (cdr vals)))
	((= i n) v)
      (bytevec-set-u16! v i (car vals)))))

(define (bytevec-subvector-u16 v start end)
  (bytevec-subvector v (* 2 start) (* 2 end)))

(define (bytevec-length-32 bv)
  (quotient (bytevec-length-16 bv) 2))

(define (bytevec-ref-u32 bv i)
  (+ (* (bytevec-ref-u16 bv (* 2 i)) #x10000)
     (bytevec-ref-u16 bv (1+ (* 2 i)))))

(define (bytevec-set-u32! bv i val)
  (bytevec-set-u16! bv (* 2 i) (quotient val #x10000))
  (bytevec-set-u16! bv (1+ (* 2 i)) (remainder val #x10000)))

(define (bytevec-subvector-u32 v start end)
  (bytevec-subvector v (* 4 start) (* 4 end)))

;;; Characters

(define (char? val)
  (primif (if-char? val) #t #f))

(define (integer->char n)
  (if (and (<= 0 n) (< n #x1000000))
      (primop integer->char n)
      (error:out-of-range n)))

(define (char->integer c)
  (if (char? c)
      (primop char->integer c)
      (error:wrong-type c)))

(define (char=? a b)
  (eq? a b))

;;; Setters

(define (setter clos)
  (closure-setter clos))

(define (init-setter-setter proc)
  (record-set! proc 3
	       (lambda (setter clos)
		 (if (closure? clos)
		     (record-set! clos 3 setter)
		     (error:wrong-type clos)))))

(init-setter-setter setter)   

;;; Records

;; (define-record name :keys creator slots)

(define (keyword-ref args key def)

  (define (ref args)
    (cond ((null? args)
	   def)
	  ((keyword? (car args))
	   (if (eq? (car args) key)
	       (cadr args)
	       (ref (cddr args))))
	  (else
	   (error "malformed key/value pairs: " args))))

  (or (and (not (null? args))
	   (keyword? (car args))
	   (ref args))
      def))

(define (keyword-gather args key)

  (define (gather args)
    (cond ((null? args)
	   '())
	  ((keyword? (car args))
	   (if (eq? (car args) key)
	       (cons (cadr args) (gather (cddr args)))
	       (gather (cddr args))))
	  (else
	   (error "malformed key/value pairs: " args))))

  (or (and (not (null? args))
	   (keyword? (car args))
	   (gather args))
      '()))

(define-macro (define-record name . args)
  (let* ((type-name (keyword-ref args :type-name
				 (symbol-append name '@type)))
	 (pred-name (keyword-ref args :predicate-name
				 (symbol-append name '?)))
	 (prefix (keyword-ref args :prefix name))
	 (slot-descs (keyword-ref args :slots args))
	 (slot-code (map (lambda (slot)
			   (let ((name (if (pair? slot) (car slot) slot)))
			     (if (pair? slot)
				 `(list ',name (lambda () ,(cadr slot)))
				 `',name)))
			 slot-descs))
	 (constructors (filter identity
			       (let ((spec (keyword-gather args :constructor)))
				 (if (null? spec)
				     (list (cons name (map (lambda (s)
							     (if (pair? s)
								 (car s)
								 s))
							   slot-descs)))
				     spec)))))
    `(begin
       ,(if (eq? (bootstrap-phase) 'compile-for-image)
	    `(bootstrap-record-type ,type-name)
	    `(define-record-type ,type-name 
	       (make-record-type ',name #f
				 (list ,@slot-code))))
       (define (,pred-name x) (record-is-a? x ,type-name))
       ,@(map (lambda (slot)
		(let* ((slot-name (if (pair? slot) (car slot) slot))
		       (accessor-name (symbol-append prefix '- slot-name)))
		  `(define-function ,accessor-name 
		     (record-type-accessor ,type-name ',slot-name))))
	      slot-descs)
       ,@(if (eq? (bootstrap-phase) 'compile-for-image)
	     ;; We need to help bootstrapping here by compiling the
	     ;; constructor into the image.  The compiler in the image
	     ;; can't run yet when the first record types are defined.
	     ;; We only handle simple constructors that use all the
	     ;; slots, tho.
	     (map (lambda (constructor)
		    (pk 'bootstrap-constructor constructor)
		    (if (equal? (cdr constructor) slot-descs)
			`(register-record-type-constructor
			  ,type-name ',(cdr constructor)
			  (lambda args (apply record ,type-name args)))
			#f))
		  constructors)
	     '())
       ,@(map (lambda (constructor)
		`(define-function ,(car constructor)
		   (record-type-constructor ,type-name
					    ',(cdr constructor))))
	      constructors))))

;; We need to pre-define some accessors so that bootstrap-record-type
;; can do its work on record-type@type itself.
;;
(define (record-type-n-fields type)             (record-ref type 0))
(define (record-type-name type)                 (record-ref type 1))
(define (record-type-ancestry type)             (record-ref type 2))
(define (record-type-slots type)                (record-ref type 3))
(define (set-record-type-slots! type val)       (record-set! type 3 val))
(define (closure-setter clos)                   (record-ref clos 3))
(define (slot-accessor slot)                    (record-ref slot 1))

(define-record record-type
  :slots (n-fields name ancestry slots constructors)
  :constructor (create-record-type n-fields name ancestry slots constructors))

(define-record slot
  index accessor initfunc)

(define (slot . args) (apply record slot@type args))

(define (make-slot type index initfunc)
  (slot index
	(lambda-with-setter ((obj)
			     (if (record-with-type?
				  obj type)
				 (record-ref obj index)
				 (error:wrong-type obj)))
			    ((val obj)
			     (if (record-with-type?
				  obj type)
				 (record-set! obj index val)
				 (error:wrong-type obj))))
	initfunc))

(define (bootstrap-record-type type)
  ;; Create the real slots
  (let* ((slots	(record-type-slots type))
	 (new-slots (map (lambda (s i)
			   (cons s (make-slot type i #f)))
			 slots (iota (length slots)))))
    (set-record-type-slots! type new-slots)))

(define (record? val)
  (primif (if-record? val #t) #t #f))

(define (record-with-type? val type)
  (primif (if-record? val type) #t #f))

(define (type-of-record rec)
  (if (record? rec)
      (primop record-desc rec)
      (error:wrong-type rec)))

(define (record-length rec)
  (primop record-ref (type-of-record rec) 0))

(define (record-ref rec idx)
  (if (and (<= 0 idx) (< idx (record-length rec)))
      (primop record-ref rec idx)
      (error:out-of-range idx)))

(define (record-set! rec idx val)
  (if (and (<= 0 idx) (< idx (record-length rec)))
      (primop record-set rec idx val)
      (error:out-of-range idx)))

(define (make-record type init)
  (primop make-record type (record-type-n-fields type) init))
  
(define (record type . values)
  (if (record-type? type)
      (let ((n (record-ref type 0))
	    (rec (make-record type #f)))
	(if (= (length values) n)
	    (begin
	      (do ((i 0 (+ i 1))
		   (v values (cdr v)))
		  ((= i n))
		(record-set! rec i (car v)))
	      rec)
	    (error:wrong-num-args)))
      (error:wrong-type type)))

(define (make-record-type name parent-type direct-slots)
  (let* ((n-parent-fields (if parent-type
			      (record-type-n-fields parent-type)
			      0))
	 (n-effective-fields (+ (length direct-slots)
				n-parent-fields))
	 (ancestry (if parent-type
		       (list->vector 
			(append (vector->list
				 (record-type-ancestry parent-type))
				(list #f)))
		       (vector #f)))
	 (type (create-record-type n-effective-fields name ancestry '() '()))
	 (slots (append
		 (if parent-type
		     (record-type-slots parent-type)
		     '())
		 (map (lambda (s i)
			(let ((name (if (pair? s) (car s) s))
			      (init (if (pair? s) (cadr s) #f))
			      (index (+ i n-parent-fields)))
			  (cons name (make-slot type index init))))
		      direct-slots
		      (iota (length direct-slots))))))
    (set-record-type-slots! type slots)
    (vector-set! ancestry (1- (vector-length ancestry)) type)
    type))

(define (make-record-type-constructor-code type slot-names)
  (let ((init-exprs (map (lambda (s)
			   (cond ((memq (car s) slot-names)
				  (car s))
				 ((slot-initfunc (cdr s))
				  `(',(slot-initfunc (cdr s))))
				 (else
				  (error "slot needs initializer: " (car s)))))
			 (record-type-slots type))))
    (eval `(lambda ,slot-names (record ',type ,@init-exprs)))))

(define (register-record-type-constructor type slot-names func)
  (set! (record-type-constructors type)
	(acons slot-names func
	       (record-type-constructors type))))

(define (record-type-constructor type slot-names)
  (or (assoc-ref (record-type-constructors type) slot-names)
      (let ((c (eval (make-record-type-constructor-code type slot-names))))
	(register-record-type-constructor type slot-names c)
	c)))

(define (record-is-a? obj type)
  (and (record? obj)
       (let ((ancestry (record-type-ancestry (type-of-record obj)))
	     (pos (1- (vector-length (record-type-ancestry type)))))
	 (and (< pos (vector-length ancestry))
	      (eq? type (vector-ref ancestry pos))))))

(define (record->list rec)
  (do ((i (record-length rec) (1- i))
       (l '() (cons (record-ref rec (1- i)) l)))
      ((zero? i) l)))

(define (record-type-slot type name)
  (or (assq-ref (record-type-slots type) name)
      (error "no such slot: " name)))

(define (record-type-accessor type name)
  (slot-accessor (record-type-slot type name)))

;;; Closures

(define-record closure
  code values debug-info setter)

(define (closure-copy clos)
  (if (closure? clos)
      (record closure@type
	      (record-ref clos 0)
	      (record-ref clos 1)
	      (record-ref clos 2)
	      (and (record-ref clos 3)
		   (closure-copy (record-ref clos 3))))
      (error:wrong-type clos)))
      
(define (unspecified-function)
  (error "unspecified"))

(define (make-unspecified-closure)
  (closure-copy unspecified-function))

(define-macro (record-case exp . clauses)
  ;; clause -> ((NAME FIELD...) BODY...)
  (let ((tmp (gensym)))
    (define (record-clause->cond-clause clause)
      (let ((pattern (car clause)))
	(if (eq? pattern 'else)
	    clause
	    (let* ((name (car pattern))
		   (args (cdr pattern))
		   (body (cdr clause)))
	      `((,(symbol-append name '?) ,tmp)
		((lambda ,args ,@body)
		 ,@(map (lambda (i)
			  `(record-ref ,tmp ,i))
			(iota (length args)))))))))
    `(let ((,tmp ,exp))
       (cond ,@(map record-clause->cond-clause clauses)
	     (else (error "unsupported record instance" ,tmp))))))

;;; Updating record types

(define-function no-such-slot-accessor
  (lambda-with-setter ((obj)
		       (error "no such slot"))
		      ((val obj)
		       (error "no such slot"))))

(define (record-type-transmogrify old-type new-type)

  ;; All transmogrifications are pre-computed and then done together
  ;; at the end.  This increases robustness and makes it possible to
  ;; change the type of records that are used in this function itself.

  (let* ((old-slots (record-type-slots old-type))
	 (new-slots (record-type-slots new-type))

	 (old-instances (find-instances old-type))
	 (new-instances (make-vector (vector-length old-instances) #f))

	 (old-accessors (list->vector (map slot-accessor (map cdr old-slots))))
	 (new-accessors (make-vector (vector-length old-accessors) #f))

	 (old-constructors (list->vector (map cdr 
					      (record-type-constructors
					       old-type))))
	 (new-constructors (make-vector (vector-length old-constructors) #f)))

    ;; Create new instances

    (let* ((update-accessors 
	    (map (lambda (n)
		   (cond ((assq-ref old-slots (car n))
			  => slot-accessor)
			 ((slot-initfunc (cdr n))
			  => (lambda (initfunc) (lambda (obj) (initfunc))))
			 (else
			  (error "no way to initialize new slot: " (car n)))))
		 new-slots))
	   (update (lambda (obj)
		     (map (lambda (a) (a obj)) update-accessors))))
      (do ((i 0 (1+ i)))
	  ((= i (vector-length old-instances)))
	(vector-set! new-instances i
		     (apply record new-type
			    (update (vector-ref old-instances i))))))

    ;; Create new accessors

    (for-each (lambda (o i)
		(let* ((n (assq-ref new-slots (car o))))
		  (vector-set! 
		   new-accessors i
		   (if n
		       (slot-accessor n)
		       (closure-copy no-such-slot-accessor)))))
	      old-slots (iota (length old-slots)))

    ;; Create new constructors

    (for-each (lambda (args+cons i)
		(vector-set! new-constructors i
			     (record-type-constructor new-type
						      (car args+cons))))
	      (record-type-constructors old-type)
	      (iota (vector-length old-constructors)))

    ;; Transmogrify everything.  The vectors with the old objects are
    ;; unreferenced after use so that the old objects are truely dead.
    ;; This matters when transmogrifying the type objects in the end.
    ;; No objects of the old type should be alive at that point.

    (transmogrify-objects old-instances new-instances)
    (set! old-instances #f)
    (transmogrify-objects old-accessors new-accessors)
    (set! old-accessors #f)
    (transmogrify-objects old-constructors new-constructors)
    (set! old-constructors #f)
    (transmogrify-objects (vector old-type) (vector new-type))))

;;; Strings

(define-record string
  :slots (bytes)
  :constructor (create-string bytes))

(define (make-string n)
  (create-string (make-bytevec n)))

(define (string . chars)
  (let ((str (make-string (length chars))))
    (do ((i 0 (+ i 1))
	 (c chars (cdr c)))
	((null? c))
      (string-set! str i (car c)))
    str))

(define (list->string list)
  (apply string list))

(define (string->list str)
  (let ((len (string-length str)))
    (do ((i (- len 1) (- i 1))
	 (l '() (cons (string-ref str i) l)))
	((< i 0) l))))

(define (string-length str)
  (bytevec-length-8 (string-bytes str)))

(define (string-ref str idx)
  (integer->char (bytevec-ref-u8 (string-bytes str) idx)))

(define (string-set! str idx chr)
  (bytevec-set-u8! (string-bytes str) idx (char->integer chr)))

(define (number->string n . opt-base)
  (let ((base (if (null? opt-base) 10 (car opt-base))))
    (list->string
     (if (< n 0)
	 (cons #\- (reverse (positive-number->char-list (- n) base)))
	 (reverse (positive-number->char-list n base))))))

(define (integer->digit d)
  (integer->char (if (< d 10)
		     (+ (char->integer #\0) d)
		     (+ (char->integer #\A) (- d 10)))))
  
(define (positive-number->char-list n b)
  (let ((q (quotient n b))
	(r (remainder n b)))
    (cons (integer->digit r)
	  (if (zero? q)
	      '()
	      (positive-number->char-list q b)))))

(define (digit->integer ch)
  (let ((d (char->integer ch)))
    (cond ((and (<= (char->integer #\0) d)
		(<= d (char->integer #\9)))
	   (- d (char->integer #\0)))
	  ((and (<= (char->integer #\a) d)
		(<= d (char->integer #\z)))
	   (+ (- d (char->integer #\a)) 10))
	  ((and (<= (char->integer #\A) d)
		(<= d (char->integer #\Z)))
	   (+ (- d (char->integer #\A)) 10))
	  (else
	   #f))))

(define (digit? ch base)
  (let ((d (digit->integer ch)))
    (and d (< d base))))

(define (string->number str . opt-base)
  (let ((base (if (null? opt-base) 10 (car opt-base))))
    (let loop ((chars (string->list str))
	       (num 0)
	       (start? #t)
	       (valid? #f)
	       (sign 1))
      (cond ((null? chars)
	     (if valid?
		 (* num sign)
		 #f))
	    ((and start? (whitespace? (car chars)))
	     (loop (cdr chars) num #t #f sign))
	    ((and start? (eq? (car chars) #\-))
	     (loop (cdr chars) num #f #f -1))
	    ((and start? (eq? (car chars) #\+))
	     (loop (cdr chars) num #f #f 1))
	    ((digit? (car chars) base)
	     (loop (cdr chars) (+ (* base num) (digit->integer (car chars)))
		   #f #t sign))
	    (else
	     #f)))))

(define (string-set-substring! str idx sub)
  (let ((n (string-length sub)))
    (do ((i 0 (+ i 1)))
	((= i n))
      (string-set! str (+ idx i) (string-ref sub i)))))

(define (string-append . strings)
  (let ((res (make-string (apply + (map string-length strings)))))
    (let loop ((s strings)
	       (i 0))
      (if (null? s)
	  res
	  (begin
	    (string-set-substring! res i (car s))
	    (loop (cdr s) (+ i (string-length (car s)))))))))

(define (string-index str ch)
  (let ((n (string-length str)))
    (let loop ((i 0))
      (cond ((= i n)
	     #f)
	    ((eq? (string-ref str i) ch)
	     i)
	    (else
	     (loop (1+ i)))))))

(define (substring str start end)
  (let ((res (make-string (- end start))))
    (do ((i start (+ i 1)))
	((= i end) res)
      (string-set! res (- i start) (string-ref str i)))))
    
;;; Functions

(define (flatten-for-apply arg1 args+rest)
  (if (null? args+rest)
      arg1
      (cons arg1 (flatten-for-apply (car args+rest) (cdr args+rest)))))

(define (apply func arg1 . args+rest)
  (:apply func (flatten-for-apply arg1 args+rest)))

;;; Dynamic environment, continuations and multiple values

(define -dynamic-env- '())

(define (call-cc func)
  (let ((old-env -dynamic-env-))
    (:call-cc (lambda (k)
		(func (lambda results
			(set! -dynamic-env- old-env)
			(apply k results)))))))

(define (call-v producer consumer)
  (:call-v producer consumer))

(define (values . results)
  (call-cc (lambda (k) (apply k results))))

(define-macro (let-values1 bindings . body)
  ;; bindings -> (sym1 sym2 ... producer)
  (let* ((n (length bindings))
	 (producer (list-ref bindings (1- n)))
	 (vals (list-head bindings (1- n))))
    (pk `(call-v (lambda () ,producer) (lambda ,vals ,@body)))))

(define (call-de env func)
  (call-cc (lambda (k)
	     (set! -dynamic-env- env)
	     (call-v func k))))

(define (dynamic-environment)
  -dynamic-env-)

;;; Parameters

(define (make-parameter init)
  (let ((global-cell (cons #f init)))
    (letrec ((parameter (lambda new-val
			  (let ((cell (or (assq parameter
						(dynamic-environment))
					  global-cell)))
			    (cond ((null? new-val)
				   (cdr cell))
				  (else
				   (set-cdr! cell (car new-val))))))))
      parameter)))

(define (call-p parameter value func)
  (call-de (acons parameter value (dynamic-environment)) func))

;;; Numbers

(define-record bignum
  limbs)

(define fixnum-max  536870911)
(define fixnum-min -536870912)

(define (fixnum? obj)
  (primif (if-fixnum? obj) #t #f))

(define (bignum-length b)
  (bytevec-length-16 (bignum-limbs b)))

(define (bignum-ref b i)
  (let* ((l (bignum-limbs b))
	 (n (bytevec-length-16 l)))
    (if (>= i n)
	(if (>= (bytevec-ref-u16 l (1- n)) #x8000)
	    #xFFFF #x0000)
	(bytevec-ref-u16 l i))))

(define (bignum-sref b i)
  (let ((v (bignum-ref b i)))
    (if (>= v #x8000)
	(- v #x10000)
	v)))

(define (bignum-negative? b)
  (let* ((l (bignum-limbs b))
	 (n (bytevec-length-16 l)))
    (>= (bytevec-ref-u16 l (1- n)) #x8000)))

(define (fixnum->bignum n)
  (:primitive split-fixnum (hi lo) (n)
	      ((bignum (bytevec-u16 lo hi)))))

(define (make-bignum-limbs n)
  (make-bytevec (* 2 n)))

(define (make-bignum-limbs-zero n)
  (let ((l (make-bignum-limbs n)))
    (do ((i 0 (1+ i)))
	((= i n))
      (bytevec-set-u16! l i 0))
    l))

(define (limbs->bignum x)
  (let loop ((i (1- (bytevec-length-16 x))))
    (let ((k (bytevec-ref-u16 x i)))
      (cond ((= i 0)
	     (if (>= k #x8000)
		 (- k #x10000)
		 k))
	    ((and (= k 0) (< (bytevec-ref-u16 x (1- i)) #x8000))
	     (loop (1- i)))
	    ((and (= k #xFFFF) (>= (bytevec-ref-u16 x (1- i)) #x8000))
	     (loop (1- i)))
	    ((and (= i 1) (< k #x2000))
	     (+ (bytevec-ref-u16 x 0) (* k #x10000)))
	    ((and (= i 1) (>= k #xe000))
	     (+ (bytevec-ref-u16 x 0) (* (- k #x10000) #x10000)))
	    (else
	     (pk-mul 'trunc-to (1+ i))
	     (bignum (bytevec-subvector-u16 x 0 (1+ i))))))))

(define (normalize-bignum b)
  (limbs->bignum (bignum-limbs b)))

(define-macro (pk-dbg . args)
  (car (last-pair args)))
  ;;`(pk ,@args))

(define-macro (pk-mul . args)
  (car (last-pair args)))
  ;;`(pk ,@args))

(define (->bignum n)
  (if (fixnum? n)
      (fixnum->bignum n)
      (if (bignum? n)
	  n
	  (error:wrong-type n))))

(define (bignum-add a b)
  (pk-mul 'add a b)
  (let* ((a-n (bignum-length a))
	 (b-n (bignum-length b))
	 (n (1+ (if (> a-n b-n) a-n b-n)))
	 (z (make-bignum-limbs n)))
    (pk-mul a-n b-n n)
    (let loop ((i 0)
	       (k 0))
      (pk-mul i)
      (if (< i n)
	  (:primitive add-fixnum2 (hi lo) ((pk-mul 'a (bignum-ref a i))
					   (pk-mul 'b (bignum-ref b i))
					   (pk-mul 'k k))
		      ((begin
			 (pk-mul 'res hi lo)
			 (bytevec-set-u16! z i lo)
			 (loop (1+ i) hi))))
	  (limbs->bignum (pk-mul 'result z))))))

(define (bignum-sub a b)
  (pk-dbg 'sub a b)
  (let* ((a-n (bignum-length a))
	 (b-n (bignum-length b))
	 (n (1+ (if (> a-n b-n) a-n b-n)))
	 (z (make-bignum-limbs n)))
    (pk-dbg a-n b-n n)
    (let loop ((i 0)
	       (k 0))
      (pk-dbg i)
      (if (< i n)
	  (:primitive sub-fixnum2 (hi lo) ((pk-dbg 'a (bignum-ref a i))
					   (pk-dbg 'b (bignum-ref b i))
					   (pk-dbg 'k k))
		      ((begin
			 (pk-dbg 'res hi lo)
			 (bytevec-set-u16! z i lo)
			 (loop (1+ i) hi))))
	  (limbs->bignum (pk-dbg 'result z))))))

(define (bignum-mul a b)

  (define (mul a b)
    (pk-mul 'mul a b)
    (let* ((a-n (bignum-length a))
	   (b-n (bignum-length b))
	   (n (+ a-n b-n))
	   (z (make-bignum-limbs-zero n)))
      (let loop-j ((j 0))
	(pk-mul 'j j)
	(if (< j a-n)
	    (let loop-i ((i 0)
			 (k 0))
	      (pk-mul 'i i)
	      (if (< i b-n)
		  (:primitive mul-fixnum2 (hi lo) ((pk-mul 'a (bignum-ref a j))
						   (pk-mul 'b (bignum-ref b i))
						   (pk-mul 'c
						       (bytevec-ref-u16
							z (+ i j)))
						   (pk-mul 'k k))
			      ((begin
				 (pk-mul 'res hi lo)
				 (bytevec-set-u16! z (+ i j) lo)
				 (loop-i (1+ i) hi))))
		  (begin
		    (bytevec-set-u16! z (+ i j) k)
		    (loop-j (1+ j)))))
	    (limbs->bignum (pk-mul 'result z))))))

  (if (bignum-negative? a)
      (if (bignum-negative? b)
	  (* (- a) (- b))
	  (- (* (- a) b)))
      (if (bignum-negative? b)
	  (- (* a (- b)))
	  (mul a b))))

(define (bignum-equal a b)
  (let* ((a-n (bignum-length a))
	 (b-n (bignum-length b))
	 (n (if (> a-n b-n) a-n b-n)))
    (let loop ((i 0))
      (if (< i n)
	  (if (= (bignum-ref a i) (bignum-ref b i))
	      (loop (1+ i))
	      #f)
	  #t))))

(define (bignum-less-than a b)
  (pk-mul '< a b)
  (let* ((a-n (bignum-length a))
	 (b-n (bignum-length b))
	 (n (if (> a-n b-n) a-n b-n)))
    (let loop ((i (1- n)))
      (pk-mul 'i i)
      (if (< i 0)
	  #f
	  (let ((v-a (if (= i (1- n)) (bignum-sref a i) (bignum-ref a i)))
		(v-b (if (= i (1- n)) (bignum-sref b i) (bignum-ref b i))))
	    (pk-mul 'a v-a 'b v-b)
	    (cond ((< v-a v-b)
		   #t)
		  ((= v-a v-b)
		   (loop (1- i)))
		  (else
		   #f)))))))

(define (bignum-shift-limbs a n)
  (let* ((a-v (bignum-limbs a))
	 (a-n (bytevec-length-16 a-v))
	 (v (make-bignum-limbs (+ a-n n))))
    (do ((i 0 (1+ i)))
	((= i a-n))
      (bytevec-set-u16! v (+ i n) (bytevec-ref-u16 a-v i)))
    (do ((i 0 (1+ i)))
	((= i n))
      (bytevec-set-u16! v i 0))
    (limbs->bignum v)))

(define (quot-fixnum2 q1 q2 v)
  (:primitive quotrem-fixnum2 (ww rr) (q1 q2 v) (ww)))

(define (bignum-quotrem q v)
  
  (define (quot1 q q-n v v-n)
    (pk-dbg 'quot1 q q-n v v-n)
    ;; compute one limb of q/v.
    ;; (q[n-1] q[n-2]) / v[n-1] is less than b.
    (let* ((ww (quot-fixnum2 (bignum-ref q (- q-n 1))
			     (bignum-ref q (- q-n 2))
			     (bignum-ref v (- v-n 1))))
	   (v-shift (bignum-shift-limbs v (- q-n v-n 1)))
	   (r (->bignum (* ww v-shift))))
      (let loop ((ww ww)
		 (r r))
	(pk-dbg 'r? r)
	(pk-dbg 'ww? ww)
	(if (> r q)
	    (loop (- ww 1)
		  (->bignum (- r v-shift)))
	    (begin
	      (pk-dbg 'q q 'r r)
	      (values ww (->bignum (- q r))))))))

  (define (non-zero-bignum-length v)
    (let loop ((n (bignum-length v)))
      (if (or (zero? n)
	      (not (zero? (bignum-ref v (1- n)))))
	  n
	  (loop (1- n)))))

  (define (quotrem q v)
    (pk-dbg 'q q)
    (pk-dbg 'v v)
    (let* ((v-n (non-zero-bignum-length v))
	   (d (quotient #x10000 (1+ (bignum-ref v (1- v-n)))))
	   (v (->bignum (* d v)))
	   (q (->bignum (* d q)))
	   (q-n (+ (bignum-length q) 1))
	   (w (make-bignum-limbs (max 0 (- q-n v-n)))))
      (let loop ((q-n q-n)
		 (q q))
	(pk-dbg 'q q 'w w)
	(if (<= q-n v-n)
	    (values (limbs->bignum w)
		    (if (zero? q) (normalize-bignum q) (quotient q d)))
	    (let-values1 (ww q (quot1 q q-n v v-n))
	      (pk-dbg 'ww ww)
	      (bytevec-set-u16! w (- q-n v-n 1) ww)
	      (loop (1- q-n) q))))))

  (if (< q 0)
      (let-values1 (w r (bignum-quotrem (->bignum (- q)) v))
        (values (- w) (- r)))
      (if (< v 0)
	  (let-values1 (w r (quotrem q (->bignum (- v))))
            (values (- w) r))
	  (quotrem q v))))

(define (bignum-quotient q v)
  (let-values1 (w r (bignum-quotrem q v))
    w))

(define (bignum-remainder q v)
  (let-values1 (w r (bignum-quotrem q v))
    r))

(define (+:2 a b)
  (if (and (fixnum? a) (fixnum? b))
      (:primitive add-fixnum (res) (a b)
		  (res
		   (bignum-add (fixnum->bignum a) (fixnum->bignum b))))
      (bignum-add (->bignum a) (->bignum b))))

(define (+ . args)
  (reduce +:2 0 args))

(define (-:2 a b)
  (if (and (fixnum? a) (fixnum? b))
      (:primitive sub-fixnum (res) (a b)
		  (res
		   (bignum-sub (fixnum->bignum a) (fixnum->bignum b))))
      (bignum-sub (->bignum a) (->bignum b))))

(define (- arg . rest)
  (if (null? rest)
      (-:2 0 arg)
      (-:2 arg (apply + rest))))

(define (*:2 a b)
  (if (and (fixnum? a) (fixnum? b))
      (:primitive mul-fixnum (res) (a b)
		  (res
		   (bignum-mul (fixnum->bignum a) (fixnum->bignum b))))
      (bignum-mul (->bignum a) (->bignum b))))

(define (* . args)
  (reduce *:2 1 args))

(define (quotient a b)
  (if (and (fixnum? a) (fixnum? b))
      (primop quotient-fixnum a b)
      (bignum-quotient (->bignum a) (->bignum b))))

(define (remainder a b)
  (if (and (fixnum? a) (fixnum? b))
      (primop remainder-fixnum a b)
      (bignum-remainder (->bignum a) (->bignum b))))

(define (= a b)
  (if (and (fixnum? a) (fixnum? b))
      (eq? a b)
      (bignum-equal (->bignum a) (->bignum b))))

(define (zero? a)
  (= a 0))

(define (< a b)
  (if (and (fixnum? a) (fixnum? b))
      (primif (if-< a b) #t #f)
      (bignum-less-than (->bignum a) (->bignum b))))

(define (<= a b)
  (or (< a b) (= a b)))

(define (> a b)
  (< b a))

(define (>= a b)
  (<= b a))

(define (1+ a)
  (+ a 1))

(define (1- a)
  (- a 1))

(define (max:2 a b)
  (if (> a b) a b))

(define (max a . rest)
  (reduce max:2 a rest))

(define (min:2 a b)
  (if (< a b) a b))

(define (min a . rest)
  (reduce min:2 a rest))

(define (iota n)
  (let loop ((res '())
	     (i 0))
    (if (>= i n)
	(reverse res)
	(loop (cons i res) (1+ i)))))

(define (even? a)
  (zero? (remainder a 2)))

(define (odd? a)
  (not (even? a)))

(define (square x)
  (* x x))

(define (expt a b)
  (cond ((< b 0)
	 (error:out-of-range b))
	((zero? b)
	 1)
	((even? b)
	 (square (expt a (quotient b 2))))
	(else
	 (* a (expt a (1- b))))))

(define (number? x)
  ;;(fixnum? x))
  (or (fixnum? x) (bignum? x)))

;;; Syscalls

(define (sys:panic)
  (primop syscall))

(define (sys:peek . vals)
  (let ((n (length vals)))
    (cond ((= n 0)
	   (primop syscall 0))
	  ((= n 1)
	   (primop syscall 0 (car vals)))
	  ((= n 2)
	   (primop syscall 0 (car vals) (cadr vals)))
	  (else
	   (primop syscall 0 (car vals) (cadr vals) (caddr vals))))))

(define (sys:write fd buf start end)
  (if (bytevec? buf)
      (if (and (<= 0 start)
	       (<= start end))
	  (if (<= end (bytevec-length-8 buf))
	      (primop syscall 2 fd buf start end)
	      (error:out-of-range end))
	  (error:out-of-range start))
      (error:wrong-type buf)))

(define (sys:read fd buf start end)
  (if (bytevec? buf)
      (if (and (<= 0 start)
	       (<= start end))
	  (if (<= end (bytevec-length-8 buf))
	      (primop syscall 3 fd buf start end)
	      (error:out-of-range end))
	  (error:out-of-range start))
      (error:wrong-type buf)))

;;; Ports

(define-record the-eof-object-type)
(define the-eof-object (the-eof-object-type))

(define (eof-object? obj)
  (eq? obj the-eof-object))

(define (output-char port ch)
  (port 0 ch))

(define (output-string port str)
  (let ((len (string-length str)))
    (do ((i 0 (+ i 1)))
	((= i len))
      (output-char port (string-ref str i)))))

(define (output-padded-string port pad-len pad-char str)
  (let ((len (string-length str)))
    (do ((i (- pad-len len) (- i 1)))
	((<= i 0))
      (output-char port pad-char))
    (do ((i 0 (+ i 1)))
	((= i len))
      (output-char port (string-ref str i)))))

(define (input-char port)
  (port 1 the-eof-object))

(define (putback-char port ch)
  (port 2 ch))

(define (peek-char port)
  (let ((ch (input-char port)))
    (putback-char port ch)
    ch))

(define (make-sys-output-port fd)
  (lambda (op arg)
    (cond ((= op 0)
	   (let ((buf (make-bytevec 1)))
	     (bytevec-set-u8! buf 0 (char->integer arg))
	     (sys:write fd buf 0 1)))
	  ((= op 1)
	   (error "can't read from output port"))
	  (else
	   (error "not supported")))))

(define (make-sys-input-port fd)
  (let ((ch #f))
    (lambda (op arg)
      (cond ((= op 1)
	     (if ch
		 (let ((r ch))
		   (set! ch #f)
		   r)
		 (let ((buf (make-bytevec 1)))
		   (let ((res (sys:read fd buf 0 1)))
		     (cond ((= res 1)
			    (integer->char (bytevec-ref-u8 buf 0)))
			   ((= res 0)
			    arg)
			   (else
			    (error "read error")))))))
	    ((= op 2)
	     (set! ch arg))
	    ((= op 0)
	     (error "can't write to input port"))
	    (else
	     (error "not supported"))))))

(define (make-string-output-port)
  (let ((buf (make-string 1024))
	(pos 0))
    (lambda (op arg)
      (cond ((eq? op 'str)
	     (substring buf 0 pos))
	    ((= op 0)
	     (string-set! buf pos arg)
	     (set! pos (1+ pos)))
	    ((= op 1)
	     (error "can't read from output port"))
	    (else
	     (error "not supported"))))))

(define (get-string-output-port-string p)
  (p 'str #f))

(define (make-string-input-port str)
  (let ((pos 0))
    (lambda (op arg)
      (cond ((= op 1)
	     (if (>= pos (string-length str))
		 arg
		 (let ((ch (string-ref str pos)))
		   (set! pos (1+ pos))
		   ch)))
	    ((= op 2)
	     (if (not (eof-object? arg))
		 (set! pos (1- pos))))
	    ((= op 0)
	     (error "can't write to input port"))
	    (else
	     (error "not supported"))))))
    
(define current-input-port (make-parameter (make-sys-input-port 0)))
(define current-output-port (make-parameter (make-sys-output-port 1)))

;;; Input/Output

(define (make-print-state port writing?)
  (cons port writing?))

(define (print-state-port state)
  (car state))

(define (print-state-writing? state)
  (cdr state))

(define (print-string str state)
  (let ((port (print-state-port state))
	(len (string-length str)))
    (if (print-state-writing? state)
	(begin
	  (output-char port #\")
	  (do ((i 0 (+ i 1)))
	      ((= i len))
	    (let ((ch (string-ref str i)))
	      (if (eq? ch #\")
		  (output-char port #\\))
	      (output-char port ch)))
	  (output-char port #\"))
	(output-string port str))))

(define (print-character ch state)
  (let ((port (print-state-port state)))
    (if (print-state-writing? state)
	(begin
	  (output-string port "#\\")
	  (case ch
	    ((#\space)
	     (output-string port "space"))
	    ((#\tab)
	     (output-string port "tab"))
	    ((#\newline)
	     (output-string port "newline"))
	    (else
	     (output-char port ch))))
	(output-char port ch))))

(define (print-number n state)
  (output-string (print-state-port state) (number->string n)))

(define max-print-length (make-parameter fixnum-max))

(define (print-list-tail p n state)
  (if (>= n (max-print-length))
      (output-string  (print-state-port state) " ...)")
      (if (pair? p)
	  (begin
	    (output-char (print-state-port state) #\space)
	    (print (car p) state)
	    (print-list-tail (cdr p) (1+ n) state))
	  (begin
	    (if (not (null? p))
		(begin
		  (output-string (print-state-port state) " . ")
		  (print p state)))
	    (output-char (print-state-port state) #\))))))
      
(define (print-list p state)
  (let ((port (print-state-port state)))
    (output-char port #\()
    (print (car p) state)
    (print-list-tail (cdr p) 1 state)))

(define (print-record r state)
  (let ((port (print-state-port state))
	(n (record-length r)))
    (output-string port "#<")
    (print (record-type-name (type-of-record r)) state)
;;     (do ((i 0 (+ i 1)))
;; 	((= i n))
;;       (output-string port " ")
;;       (print (record-ref r i) state))
    (output-string port ">")))

(define (print-vector v state)
  (let ((port (print-state-port state))
	(n (vector-length v)))
    (output-string port "#(")
    (do ((i 0 (+ i 1))
	 (sp #f #t))
	((or (= i n) (> i (max-print-length))))
      (if sp
	  (output-string port " "))
      (print (vector-ref v i) state))
    (output-char port #\))))

(define (print-bytevec v state)
  (let ((port (print-state-port state))
	(n (bytevec-length-16 v))
	(n8 (bytevec-length-8 v)))
    (output-string port "/")
    (do ((i 0 (+ i 1)))
	((= i n))
      (output-padded-string port
			    4 #\0
			    (number->string (bytevec-ref-u16 v i) 16))
      (output-string port "/"))
    (cond ((odd? n8)
	   (output-padded-string port
				 2 #\0
				 (number->string
				  (bytevec-ref-u8 v (1- n8)) 16))
	   (output-string port "/")))))

(define (print-symbol-name n state)
  (let ((port (print-state-port state)))
    (for-each (lambda (ch)
		(if (delimiter? ch)
		    (output-char port #\\))
		(output-char port ch))
	      (string->list n))))

(define (print-symbol s state)
  (print-symbol-name (symbol->string s) state))

(define (print-keyword k state)
  (output-char (print-state-port state) #\:)
  (print (keyword->symbol k) state))

(define (print-pathname p state)
  (let ((o (pathname-parent-offset p))
	(c (pathname-components p)))

    (define (print-comps comps need-slash)
      (cond ((not (null? comps))
	     (if need-slash
		 (output-char (print-state-port state) #\/))
	     (print (car comps) state)
	     (print-comps (cdr comps) #t))))
      
    (cond ((and (zero? o) (null? c))
	   (output-char (print-state-port state) #\.))
	  ((< o 0)
	   (output-char (print-state-port state) #\/)
	   (print-comps c #f))
	  (else
	   (do ((i 0 (1+ i))
		(need-slash #f #t))
	       ((= i o)
		(print-comps c need-slash))
	     (if need-slash
		 (output-char (print-state-port state) #\/))
	     (output-string (print-state-port state) ".."))))))

(define (print-code val state)
  (output-string (print-state-port state) "#<code ")
  (print (code-insn-length val) state)
  (output-string (print-state-port state) " ")
  (print (code-lit-length val) state)
  (output-string (print-state-port state) ">"))

(define print-depth (make-parameter 0))
(define max-print-depth (make-parameter 10))

(define (print val state)
  (if (< (print-depth) (max-print-depth))
      (call-p print-depth (+ 1 (print-depth))
	      (lambda ()
		(let ((port (print-state-port state)))
		  (cond ((eq? #t val)
			 (output-string port "#t"))
			((eq? #f val)
			 (output-string port "#f"))
			((eq? '() val)
			 (output-string port "()"))
			((eq? (begin) val)
			 (output-string port "#<unspecified>"))
			((char? val)
			 (print-character val state))
			((number? val)
			 (print-number val state))
			((string? val)
			 (print-string val state))
			((symbol? val)
			 (print-symbol val state))
			((keyword? val)
			 (print-keyword val state))
			((pathname? val)
			 (print-pathname val state))
			((pair? val)
			 (print-list val state))
			((vector? val)
			 (print-vector val state))
			((bytevec? val)
			 (print-bytevec val state))
			((code? val)
			 (print-code val state))
			((record? val)
			 (print-record val state))
			(else
			 (output-string port "#<...>"))))))
      (output-string (print-state-port state) "#")))

(define (pretty-print val)
  ;; beauty is in the eye of the beholder
  (display val))

(define (display val)
  (print val (make-print-state (current-output-port) #f)))

(define (write val)
  (print val (make-print-state (current-output-port) #t)))

(define (newline)
  (display #\nl))

(define (make-parse-state port)
  port)

(define (parse-state-port state)
  state)

(define (whitespace? ch)
  (or (eq? ch #\space)
      (eq? ch #\tab)
      (eq? ch #\newline)))

(define (linear-whitespace? ch)
  (or (eq? ch #\space)
      (eq? ch #\tab)))

(define (delimiter? ch)
  (or (eof-object? ch)
      (whitespace? ch)
      (eq? ch #\()
      (eq? ch #\))
      (eq? ch #\')
      (eq? ch #\;)))

(define (parse-whitespace state)
  (let ((ch (input-char (parse-state-port state))))
    (cond ((whitespace? ch)
	   (parse-whitespace state))
	  ((eq? ch #\;)
	   (parse-comment state)
	   (parse-whitespace state))
	  (else
	   (putback-char (parse-state-port state) ch)))))

(define (parse-comment state)
  (let ((ch (input-char (parse-state-port state))))
    (if (not (eq? ch #\newline))
	(parse-comment state))))

(define (parse-token state)
  (let loop ((chars '()))
    (define (make-token)
      (list->string (reverse chars)))
    (let ((ch (input-char (parse-state-port state))))
      (cond ((eof-object? ch)
	     (if (null? chars)
		 ch
		 (make-token)))
	    ((delimiter? ch)
	     (putback-char (parse-state-port state) ch)
	     (make-token))
	    (else
	     (loop (cons ch chars)))))))

(define (parse-number-or-pathname state)
  (let ((tok (parse-token state)))
    (or (string->number tok)
	(string->pathname tok))))

(define (parse-hex state)
  (let ((tok (parse-token state)))
    (or (string->number tok 16)
	(error "not a hexadecimal number: " tok))))

(define (must-parse ch state)
  (parse-whitespace state)
  (if (not (eq? ch (input-char (parse-state-port state))))
      (error "missing " ch)))

(define (parse-list state)
  (parse-whitespace state)
  (let ((ch (input-char (parse-state-port state))))
    (if (eq? ch #\))
	'()
	(begin
	  (putback-char (parse-state-port state) ch)
	  (let ((elt (parse state)))
	    (if (eof-object? elt)
		(error "unexpected end of input"))
	    (if (and (pathname? elt)
		     (zero? (pathname-parent-offset elt))
		     (null? (pathname-components elt)))
		(let ((elt (parse state)))
		  (must-parse #\) state)
		  elt)
		(cons elt (parse-list state))))))))

(define (parse-string state)
  (let ((port (parse-state-port state)))
    (let loop ((ch (input-char port))
	       (chars '()))
      (cond ((eq? ch #\")
	     (list->string (reverse chars)))
	    ((eq? ch #\\)
	     (let ((ch (input-char port)))
	       (let ((ch (case ch
			   ((#\n)
			    #\newline)
			   (else
			    ch))))
		 (loop (input-char port) (cons ch chars)))))
	  ((eof-object? ch)
	   (error "unexpected end of input in string literal"))
	    (else
	     (loop (input-char port) (cons ch chars)))))))

(define (parse-char state)
  (let ((ch (input-char (parse-state-port state))))
    (if (delimiter? ch)
	ch
	(begin
	  (putback-char (parse-state-port state) ch)
	  (let ((tok (parse-token state)))
	    (if (eof-object? tok)
		(error "unexpected end of input in character literal"))
	    (if (= (string-length tok) 1)
		(string-ref tok 0)
		(cond
		 ((equal? tok "space")   #\space)
		 ((equal? tok "newline") #\newline)
		 ((equal? tok "tab")     #\tab)
		 (else
		  (error "unrecognized character name: " tok)))))))))

(define (parse-keyword state)
  (symbol->keyword (parse state)))

(define (parse-sharp state)
  (let ((ch (input-char (parse-state-port state))))
    (cond ((eq? ch #\()
	   (list->vector (parse-list state)))
	  ((eq? ch #\t)
	   #t)
	  ((eq? ch #\f)
	   #f)
	  ((eq? ch #\\)
	   (parse-char state))
	  ((eq? ch #\x)
	   (parse-hex state))
	  ((eof-object? ch)
	   (error "unexpected end of input in # construct"))
	  (else
	   (error "unsupported # construct: #" ch)))))

(define (parse state)
  (parse-whitespace state)
  (let ((ch (input-char (parse-state-port state))))
    (cond ((eof-object? ch)
	   ch)
	  ((eq? ch #\()
	   (parse-list state))
	  ((eq? ch #\")
	   (parse-string state))
	  ((eq? ch #\:)
	   (parse-keyword state))
	  ((eq? ch #\#)
	   (parse-sharp state))
	  ((eq? ch #\')
	   (list 'quote (parse state)))
	  ((eq? ch #\`)
	   (list 'quasiquote (parse state)))
	  ((eq? ch #\,)
	   (let ((ch (input-char (parse-state-port state))))
	     (if (eq? ch #\@)
		 (list 'unquote-splicing (parse state))
		 (begin
		   (putback-char (parse-state-port state) ch)
		   (list 'unquote (parse state))))))
	  ((delimiter? ch)
	   (error "unexpected delimiter: " ch))
	  (else
	   (putback-char (parse-state-port state) ch)
	   (parse-number-or-pathname state)))))

(define (read . opt-port)
  (parse (make-parse-state (if (null? opt-port)
			       (current-input-port)
			       (car opt-port)))))

(define (read-line)
  (let loop ((res '())
	     (in-comment #f)
	     (escaped #f))
    (let ((ch (input-char (current-input-port))))
      (cond ((eof-object? ch)
	     (if (null? res)
		 ch
		 (reverse res)))
	    ((and (eq? ch #\newline)
		  (not escaped))
	     (reverse res))
	    ((eq? ch #\\)
	     (loop res in-comment #t))
	    ((or in-comment
		 (whitespace? ch))
	     (loop res in-comment #f))
	    ((eq? ch #\;)
	     (loop res #t #f))
	    (else
	     (putback-char (current-input-port) ch)
	     (loop (cons (read) res) in-comment escaped))))))

;;; Vectors

(define (vector? val)
  (primif (if-vector? val) #t #f))

(define (vector-length vec)
  (if (vector? vec)
      (primop vector-length vec)
      (error:wrong-type vec)))

(define (vector-ref vec idx)
  (if (and (<= 0 idx) (< idx (vector-length vec)))
      (primop vector-ref vec idx)
      (error:out-of-range idx)))

(define (vector-set! vec idx val)
  (if (and (<= 0 idx) (< idx (vector-length vec)))
      (primop vector-set vec idx val)
      (error:out-of-range idx)))

(define (make-vector n init)
  (if (fixnum? n)
      (primop make-vector n init)
      (error:out-of-range n)))

(define (vector . values)
  (let ((n (length values)))
    (let ((vec (make-vector n #f)))
      (do ((i 0 (+ i 1))
	   (v values (cdr v)))
	  ((= i n))
	(vector-set! vec i (car v)))
      vec)))

(define (list->vector lst)
  (apply vector lst))

(define (vector->list vec)
  (do ((i 0 (1+ i))
       (r '() (cons (vector-ref vec i) r)))
      ((= i (vector-length vec)) (reverse r))))

(define (subvector v start end)
  (let ((s (make-vector (- end start) #f)))
    (do ((i start (1+ i)))
	((= i end))
      (vector-set! s (- i start) (vector-ref v i)))
    s))

(define (vector-copy v)
  (subvector v 0 (vector-length v)))

;;; Code

(define (code? val)
  (primif (if-code? val) #t #f))

(define (code-insn-length code)
  (if (code? code)
      (primop code-insn-length code)
      (error:wrong-type)))

(define (code-lit-length code)
  (if (code? code)
      (primop code-lit-length code)
      (error:wrong-type)))

(define (make-code insn-length lit-length)
  (if (fixnum? insn-length)
      (if (fixnum? lit-length)
	  (primop make-code insn-length lit-length)
	  (error:wrong-type lit-length))
      (error:wrong-type insn-length)))

(define (code-insn-ref-u8 code idx)
  (if (code? code)
      (if (and (<= 0 idx) (< idx (* 4 (code-insn-length code))))
	  (primop bytevec-ref-u8 code idx)
	  (error:out-of-range idx))
      (error:wrong-type code)))

(define (code-insn-ref-u16 code idx)
  (if (code? code)
      (if (and (<= 0 idx) (< idx (* 2 (code-insn-length code))))
	  (primop bytevec-ref-u16 code idx)
	  (error:out-of-range idx))
      (error:wrong-type code)))

(define (code-insn-set-u16! code idx val)
  (if (code? code)
      (if (and (<= 0 idx) (< idx (* 2 (code-insn-length code))))
	  (if (and (<= 0 val) (< val #x10000))
	      (primop bytevec-set-u16 code idx val)
	      (error:out-of-range val))
	  (error:out-of-range idx))
      (error:wrong-type code)))

(define (code-lit-set! code idx val)
  (if (code? code)
      (if (and (<= 0 idx) (< idx (code-lit-length code)))
	  (primop vector-set code (+ (code-insn-length code) idx) val)
	  (error:out-of-range idx))
      (error:wrong-type code)))

(define (code-lit-ref code idx)
  (if (code? code)
      (if (and (<= 0 idx) (< idx (code-lit-length code)))
	  (primop vector-ref code (+ (code-insn-length code) idx))
	  (error:out-of-range idx))
      (error:wrong-type code)))

(define (code insns lits)
  (let* ((insn-length (bytevec-length-32 insns))
	 (insn-length-16 (* 2 insn-length))
	 (lit-length (vector-length lits))
	 (code (make-code insn-length lit-length)))
    (do ((i 0 (1+ i)))
	((= i insn-length-16))
      (code-insn-set-u16! code i (bytevec-ref-u16 insns i)))
    (do ((i 0 (1+ i)))
	((= i lit-length))
      (code-lit-set! code i (vector-ref lits i)))
    code))

(define (code-debug-info code)
  (code-lit-ref code 0))

;;; equal?

(define (equal? a b)
  (or (eq? a b)
      (and (string? a) (string? b)
	   (string-equal? a b))
      (and (symbol? a) (symbol? b)
	   (symbol-equal? a b))
      (and (pair? a) (pair? b)
	   (pair-equal? a b))
      (and (vector? a) (vector? b)
	   (vector-equal? a b))
      (and (record? a) (record-with-type? b (type-of-record a))
	   (record-equal? a b))))

(define (string-equal? a b)
  (let ((len (string-length a)))
    (and (= len (string-length b))
	 (do ((i 0 (+ i 1)))
	     ((or (= i len)
		  (not (equal? (string-ref a i) (string-ref b i))))
	      (= i len))))))

(define (vector-equal? a b)
  (let ((len (vector-length a)))
    (and (= len (vector-length b))
	 (do ((i 0 (+ i 1)))
	     ((or (= i len)
		  (not (equal? (vector-ref a i) (vector-ref b i))))
	      (= i len))))))

(define (record-equal? a b)
  (let ((len (record-length a)))
    (do ((i 0 (+ i 1)))
	((or (= i len)
	     (not (equal? (record-ref a i) (record-ref b i))))
	 (= i len)))))

(define (symbol-equal? a b)
  (eq? a b))

(define (pair-equal? a b)
  (and (equal? (car a) (car b))
       (equal? (cdr a) (cdr b))))

;;; Bootinfo

(define-macro (bootinfo)
  `(:bootinfo))

;;; Hash tables

(define (mix-hash n . vals)
  (let loop ((h 0)
	     (vals vals))
    (if (null? vals)
	h
	(loop (remainder (+ (* h 37) (car vals)) n)
	      (cdr vals)))))

(define (string-hash n str)
  (apply mix-hash n (map char->integer (string->list str))))

(define (symbol-hash n sym)
  (string-hash n (symbol->string sym)))

(define (pair-hash n p)
  (mix-hash n (hash (car p) n) (hash (cdr p) n)))

(define (vector-hash n vec)
  (apply mix-hash n (map (lambda (e) (hash e n)) (vector->list vec))))

(define (record-hash n rec)
  (apply mix-hash n (map (lambda (e) (hash e n)) (record->list rec))))

(define (hash obj n)
  (cond
   ((string? obj)
    (string-hash n obj))
   ((symbol? obj)
    (symbol-hash n obj))
   ((pair? obj)
    (pair-hash n obj))
   ((vector? obj)
    (vector-hash n obj))
   ((record? obj)
    (record-hash n obj))
   ((number? obj)
    (remainder obj n))
   ((char? obj)
    (hash (char->integer obj) n))
   ((eq? #t obj)
    (remainder 10 n))
   ((eq? #f obj)
    (remainder 18 n))
   ((eq? '() obj)
    (remainder 2 n))
   (else
    (error:wrong-type obj))))

(define (make-hash-table n)
  (make-vector n '()))

(define (hash-ref tab key)
  (assoc-ref (vector-ref tab (hash key (vector-length tab))) key))

(define (hash-set! tab key val)
  (let* ((h (hash key (vector-length tab)))
	 (c (assoc key (vector-ref tab h))))
    (if c
	(set-cdr! c val)
	(vector-set! tab h (acons key val (vector-ref tab h))))))

(define (make-hashq-table n)
  (let ((v (make-vector n '())))
    (set-hashq-vectors (cons v (get-hashq-vectors)))
    v))

(define (hashq-ref vec key)
  (if (vector? vec)
      (and=> (primop syscall 4 vec key #f) cdr)
      (error:wrong-type vec)))

(define (hashq-set! vec key val)
  (if (vector? vec)
      (let* ((new-pair (acons key val '()))
	     (c (primop syscall 4 vec key new-pair)))
	(if c
	    (set-cdr! c val)))
      (error:wrong-type vec)))

(define (hashq-del! vec key)
  (if (vector? vec)
      (primop syscall 5 vec key)
      (error:wrong-type vec)))

(define (hashq->alist! vec)
  (if (vector? vec)
      (primop syscall 6 vec)
      (error:wrong-type vec)))

(define (alist->hashq! alist vec)
  (if (vector? vec)
      (primop syscall 7 alist vec)
      (error:wrong-type vec)))

(define (get-hashq-vectors)
  (primop syscall 8 -3))

(define (set-hashq-vectors v)
  (primop syscall 9 -3 v))

(define (hashq-fold init proc vec)
  (let ((alst (hashq->alist! vec)))
    (let loop ((lst alst)
	       (res init))
      (cond ((null? lst)
	     (alist->hashq! alst vec)
	     res)
	    (else
	     (loop (cdr lst) (proc (car lst) res)))))))

;;; Symbols

(define-record symbol
  name)

(define boot-symbols (car (bootinfo)))

(define symbols (make-hash-table 511))

(define (symbol->string sym)
  (symbol-name sym))

(define (string->symbol str)
  (if (string? str)
      (or (hash-ref symbols str)
	  (let ((sym (symbol str)))
	    (hash-set! symbols str sym)
	    sym))
      (error:wrong-type str)))

(define (symbol-append . syms)
  (string->symbol (apply string-append (map symbol->string syms))))

(define (init-symbols)
  (for-each (lambda (sym)
	      (hash-set! symbols (symbol->string sym) sym))
	    boot-symbols))

(init-symbols)

(define -gensym-counter- 0)

(define (gensym)
  (set! -gensym-counter- (+ -gensym-counter- 1))
  (string->symbol (string-append " G" (number->string -gensym-counter-))))

;;; Keywords

(define-record keyword
  symbol)

(define boot-keywords (cadr (bootinfo)))

(define keywords (make-hashq-table 31))

(define (init-keywords)
  (for-each (lambda (key)
	      (hashq-set! keywords (keyword->symbol key) key))
	    boot-keywords))

(init-keywords)

(define (keyword->symbol key)
  (keyword-symbol key))

(define (symbol->keyword sym)
  (if (symbol? sym)
      (let ((key (hashq-ref keywords sym)))
	(or key
	    (let ((key (keyword sym)))
	      (hashq-set! keywords sym key)
	      key)))
      (error:wrong-type)))

;;; Extended argument lists (DRAFT)

;; The fundamental function to handle keyword arguments etc is
;; PARSE-EXTENDED-ARGUMENTS.  Given a argument specification and a
;; list of the actual parameters, it will return the values for the
;; arguments (as 'multiple values') in an order corresponding to the
;; argument specification.
;;
;; For example:
;;
;;     (parse-extended-arguments '(:flags v w :keys x y z :rest a b r)
;;                               '(:v 1 :x 2 3 :y 4 5 6)
;;     => #t #f 2 4 #<unspecified> 1 3 (5 6)
;;     ;; v  w  x y z              a b r
;;
;; A argument specification consists of keywords followed by a list of
;; symbols.  They keyword can be either :flags, :keys, or :rest.
;;
;; The list of actual parameters is scanned from left to right.  When
;; the current parameter is the keyword :rest, scanning stops and the
;; remaining parameters are assigned to the rest arguments,
;; effectively as if scanning would continue but keywords are not
;; handled specially.  If it is a keyword but not :rest, it must
;; correspond to one of the :flag or :key arguments.  If it is a flag
;; argument, that flag is set to true.  If it is a key argument, the
;; next parameter value is consumed and is used as the value for this
;; key.  If the current parameter is not a keyword, it is used as the
;; value for the next unused rest argument.  The last rest argument
;; accumulates all these values as a list.
;;
;; When a flag argument didn't receive a value during the scan, it is
;; set to #f.  When a key argument or rest argument didn't receive a
;; value, it is set to #<unspecified>.  When there are no rest
;; arguments at all and a value should be assigned to one, an error is
;; signalled.
;;
;; Syntactic sugar is available in the form of LAMBDA* and DEFINE*.
;; These macros are actually slightly more efficient since they
;; pre-compile the extended argument specification.

(define-record extarg-spec
  defaults names flags keys rest rest-first rest-last)

(define (parse-extarg-spec spec)
  (let loop ((spec spec)
	     (cur-key #f)
	     (index 0)
	     (defs '())
	     (names '())
	     (flags '())
	     (keys '())
	     (rest '())
	     (rest-first #f)
	     (rest-last #f))
    (pk 'on spec)
    (cond ((null? spec)
	   (extarg-spec (apply vector (reverse defs))
			(reverse names)
			flags
			keys
			rest
			rest-first
			rest-last))
	  ((keyword? (car spec))
	   (loop (cdr spec) (car spec)
		 index defs names
		 flags
		 keys
		 rest rest-first rest-last))
	  ((symbol? (car spec))
	   (case cur-key
	     ((:flags)
	      (loop (cdr spec) cur-key
		    (1+ index) (cons #f defs) (cons (car spec) names)
		    (acons (symbol->keyword (car spec)) index flags)
		    keys
		    rest rest-first rest-last))
	     ((:keys)
	      (loop (cdr spec) cur-key
		    (1+ index) (cons (begin) defs) (cons (car spec) names)
		    flags
		    (acons (symbol->keyword (car spec)) index keys)
		    rest rest-first rest-last))
	     ((:rest)
	      (loop (cdr spec) cur-key
		    (1+ index) (cons '() (if rest-first
					     (cons (begin) (cdr defs))
					     defs))
		    (cons (car spec) names)
		    flags
		    keys
		    (acons (symbol->keyword (car spec)) index rest) 
		    (or rest-first index) index))
	     ((#f)
	      (error "argument list must start with a keyword"))
	     (else
	      (error "unrecognized argument keyword: " cur-key))))
	  (else
	   (pk (car spec) (keyword? (car spec)))
	   (error "unrecognized argument syntax: " (car spec))))))

(define (match-extarg-spec spec parms)
  (let ((values (vector-copy (extarg-spec-defaults spec)))
	(rest-last (extarg-spec-rest-last spec)))
    (let loop ((parms parms)
	       (rest-next (extarg-spec-rest-first spec))
	       (rest #f))
      (cond ((null? parms)
	     (if rest-last
		 (vector-set! values rest-last
			      (reverse (vector-ref values rest-last))))
	     values)
	    ((or rest
		 (not (keyword? (car parms))))
	     (if (not rest-next)
		 (error "too many parameters"))
	     (if (>= rest-next rest-last)
		 (vector-set! values rest-last
			      (cons (car parms)
				    (vector-ref values rest-last)))
		 (vector-set! values rest-next (car parms)))
	     (loop (cdr parms)
		   (1+ rest-next)
		   rest))
	    ((eq? :rest (car parms))
	     (loop (cdr parms) rest-next #t))
	    ((assq-ref (extarg-spec-flags spec) (car parms))
	     => (lambda (i)
		  (vector-set! values i #t)
		  (loop (cdr parms) rest-next rest)))
	    ((assq-ref (extarg-spec-keys spec) (car parms))
	     => (lambda (i)
		  (if (null? (cdr parms))
		      (error "missing value for keyword argument: " 
			     (car parms)))
		  (vector-set! values i (cadr parms))
		  (loop (cddr parms) rest-next rest)))
	    (else
	     (error "unknown keyword in arguments: " (car parms)))))))

(define (parse-extended-arguments spec parms)
  (match-extarg-spec (parse-extarg-spec spec) parms))

(define-macro (lambda* spec . body)
  (let ((spec (parse-extarg-spec spec)))
    `(let ((func (lambda ,(extarg-spec-names spec) ,@body)))
       (lambda parms
	 (apply func (vector->list (match-extarg-spec ',spec parms)))))))

(define-macro (define* head . body)
  (let ((name (car head))
	(spec (cdr head)))
    `(define-function ,name (lambda* ,spec ,@body))))

;;; Pathnames

;; A pathname is a list symbols (called the pathname's components) and
;; a flag that specifies whether it should be interpreted from the
;; root location (called a "absolute pathname") or from the current
;; location (called a "relative pathname").  Thus, a absolute pathname
;; with a empty list of symbols refers to the root, and a empty
;; relative pathname refers to the current location.
;;
;; A relative pathname has a 'parent offset' that specifies how many
;; hierarchy levels one should go up before starting to lookup the
;; first component.  This parent offset is written and read as a
;; sequence of ".." pseudo components.  Real components can not be
;; symbols with the name "..".
;;
;; The realtive pathname with no compontents is written and read as
;; ".".
;;
;; A naked symbol is recognized as a relative pathname with that
;; symbol as its component.

(define-record pathname*
  parent-offset components)

(define (pathname parent-offset components)
  (if (and (zero? parent-offset) (= (length components) 1)
	   (symbol? (car components)))
      (car components)
      (pathname* parent-offset components)))

(define (pathname? obj)
  (or (symbol? obj)
      (pathname*? obj)))

(define (pathname-absolute? obj)
  (< (pathname-parent-offset obj) 0))

(define (pathname-parent-offset obj)
  (if (symbol? obj)
      0
      (pathname*-parent-offset obj)))

(define (pathname-components obj)
  (if (symbol? obj)
      (list obj)
      (pathname*-components obj)))

(define (string->pathname str)
  (cond 
   ((equal? str "/")
    (pathname -1 '()))
   ((equal? str ".")
    (pathname 0 '()))
   (else
    (let ((len (string-length str)))
      (let loop ((start 0)
		 (cur 0)
		 (offset 0)
		 (comps '()))

	(define (consume-comp)
	  (let ((n (substring str start cur)))
	    (cond ((equal? n "")
		   (error "pathname component can not be empty"))
		  ((equal? n ".")
		   (error "pathname component can not be '.'"))
		  ((equal? n "..")
		   (if (and (>= offset 0) (null? comps))
		       (loop (1+ cur) (1+ cur) (1+ offset) comps)
		       (error "internal pathname component can not be '..'")))
		  (else
		   (loop (1+ cur) (1+ cur) offset 
			 (cons (string->symbol n) comps))))))
		  
	(cond ((> cur len)
	       (pathname offset (reverse comps)))
	      ((= cur len)
	       (consume-comp))
	      ((eq? (string-ref str cur) #\/)
	       (if (zero? cur)
		   (loop 1 1 -1 '())
		   (consume-comp)))
	      (else
	       (loop start (1+ cur) offset comps))))))))

(define (pathname-concat p1 p2)
  (let ((o1 (pathname-parent-offset p1))
	(l1 (length (pathname-components p1)))
	(o2 (pathname-parent-offset p2)))
    (cond ((< o2 0)
	   p2)
	  ((<= o2 l1)
	   (pathname o1 (append (list-head (pathname-components p1)
					   (- l1 o2))
				(pathname-components p2))))
	  ((< o1 0)
	   (error "root directory has no parent"))
	  (else
	   (pathname (+ o1 (- o2 l1)) (pathname-components p2))))))

(define (pathname-head p n)
  (pathname (pathname-parent-offset p)
	    (list-head (pathname-components p) n)))

;;; Reverse scanning

(define (find-referrers obj)
  (let* ((vec (make-vector 200 #f))
	 (count (primop syscall 12 obj vec)))
    (if (<= count 200)
	(subvector vec 0 count)
	(let* ((vec (make-vector count #f))
	       (count2 (primop syscall 12 obj vec)))
	  (cond ((not (= count count2))
		 (pk 'whoops)
		 (subvector vec 0 count2))
		(else
		 vec))))))

(define (find-instances type)
  (let* ((vec (make-vector 200 #f))
	 (count (primop syscall 13 type vec)))
    (if (<= count 200)
	(subvector vec 0 count)
	(let* ((vec (make-vector count #f))
	       (count2 (primop syscall 13 type vec)))
	  (cond ((not (= count count2))
		 (pk 'whoops)
		 (subvector vec 0 count2))
		(else
		 vec))))))

(define (transmogrify-objects from to)
  (if (and (vector? from) (vector? to)
	   (= (vector-length from) (vector-length to)))
      (primop syscall 14 from to)
      (error "need two parallel vectors: " from to)))

;;; Variables and macros

(define-record variable
  value)

(define (variable-ref var)
  (variable-value var))

(define (variable-set! var val)
  (set! (variable-value var) val))

(define-record macro
  transformer)

;;; Directories

(define entry-value car)
(define set-entry-value! set-car!)
(define entry-attributes cdr)
(define set-entry-attributes! set-cdr!)

(define (make-entry val attrs)
  (cons val attrs))

(define (entry-attribute ent attr)
  (assq-ref (entry-attributes ent) attr))

(define (set-entry-attribute! ent attr val)
  (set-entry-attributes! ent (acons attr val
				    (assq-del (entry-attributes ent) attr))))

(define (entry-merge-attrs! ent attrs)
  ;; XXX - cheap shot
  (for-each (lambda (attr)
	      (set-entry-attribute! ent (car attr) (cdr attr)))
	    attrs))

(define (list-entry name ent verbose)
  (let* ((value (entry-value ent))
	 (type (cond ((directory? value)   #\d)
		     ((variable? value)    #\v)
		     ((closure? value)     #\p)
		     ((record-type? value) #\t)
		     ((macro? value)       #\m)
		     ((not value)          #\!)
		     (else                 #\?))))
    (display type)
    (display #\space)
    (display name)
    (newline)
    (if verbose
	(for-each (lambda (attr)
		    (display #\space)
		    (display #\space)
		    (display (car attr))
		    (display #\tab)
		    (display (cdr attr))
		    (newline))
		  (entry-attributes ent)))))

(define-record directory
  entries)

(define (directory* n)
  (directory (make-hashq-table n)))

(define (directory-lookup dir sym)
  (hashq-ref (directory-entries dir) sym))

(define (directory-enter dir sym ent)
  (hashq-set! (directory-entries dir) sym ent))

(define (directory-remove dir sym)
  (hashq-del! (directory-entries dir) sym))

(define (directory-list-bindings dir)
  (hashq-fold '() cons (directory-entries dir)))

(define root-directory (directory* 31))
(define root-directory-entry (make-entry root-directory '()))

(define boot-directory (directory* 1023))
(directory-enter root-directory 'boot (make-entry boot-directory '()))

(define boot-bindings (caddr (bootinfo)))

(define (init-boot-directory)
  (for-each (lambda (binding)
	      (let ((sym (car binding))
		    (ent (cdr binding)))
		(directory-enter boot-directory sym ent)))
	    boot-bindings))

(init-boot-directory)

(define current-directory (make-parameter root-directory-entry))
(define current-directory-path (make-parameter (pathname -1 '())))

(define open-directories (make-parameter '()))

;; LOOKUP-PARENT normally returns two values: a directory and a
;; symbol, where the symbol is the last component of NAME and the
;; directory is the parent of it according to NAME.  When NAME refers
;; to the root directory, LOOKUP-PARENT returns the root directory and
;; #f.

(define (lookup-parent name)

  (cond ((symbol? name)
	 (values (entry-value (current-directory))
		 name))
	(else
	 (let ((name (pathname-concat (current-directory-path) name)))

	   (define (lookup-in-dir dir comps len)
	     (cond ((null? comps)
		    (values dir #f))
		   ((not (directory? dir))
		    (error "not a directory: " (pathname-head name len)))
		   ((null? (cdr comps))
		    (values dir (car comps)))
		   (else
		    (lookup-in-dir (entry-value
				    (or (directory-lookup dir (car comps))
					(error "not found: "
					       (pathname-head name
							      (1+ len)))))
				   (cdr comps)
				   (1+ len)))))
	 
	   (lookup-in-dir root-directory (pathname-components name) 0)))))
	 
(define (lookup* name)
  (let-values1 (dir sym (lookup-parent name))
    (if (not sym)
	root-directory-entry
	(directory-lookup dir sym))))

(define (lookup name)
  (or (lookup* name)
      (and (symbol? name)
	   (or-map (lambda (dir)
		     (directory-lookup dir name))
		   (open-directories)))))

(define (enter name proc)
  (let-values1 (dir sym (lookup-parent name))
    (if (not sym)
	(error "can't modify root directory")
	(let ((ent (directory-lookup dir sym)))
	  (cond (ent
		 (proc ent)
		 ent)
		(else
		 (if (lookup name)
		     (pk 'shadows name))
		 (let ((ent (proc #f)))
		   (directory-enter dir sym ent)
		   ent)))))))

(define (variable-lookup name)
  (let ((ent (lookup name)))
    (cond ((not ent)
	   (error "undefined: " name))
	  ((variable? (entry-value ent))
	   (entry-value ent))
	  (else
	   (error "not a variable:" name)))))

(define (function-lookup name)
  (let ((ent (lookup name)))
    (cond ((not ent)
	   (error "undefined: " name))
	  ((closure? (entry-value ent))
	   (entry-value ent))
	  (else
	   (error "not a function:" name)))))

(define (variable-declare name . attrs)
  (entry-value
   (enter name
	  (lambda (old)
	    (cond ((not old)
		   (make-entry (variable (begin))  attrs))
		  ((variable? (entry-value old))
		   (entry-merge-attrs! old attrs)
		   old)
		  (else
		   (error "already declared: " name)))))))

(define (function-declare name . attrs)
  (entry-value
   (enter name
	  (lambda (old)
	    (cond ((not old)
		   (make-entry (make-unspecified-closure) attrs))
		  ((closure? (entry-value old))
		   (entry-merge-attrs! old attrs)
		   old)
		  (else
		   (error "already declared: " name)))))))

(define (macro-lookup name)
  (let ((ent (lookup name)))
    (cond ((or (not ent) (not (macro? (entry-value ent))))
	   #f)
	  (else
	   (macro-transformer (entry-value ent))))))

(define (macro-define name val)
  (enter name
	 (lambda (old)
	   (cond ((not old)
		  (make-entry (macro val) '()))
		 ((macro? (entry-value old))
		  (set-entry-value! old (macro val))
		  old)
		 (else
		  (error "already declared: " name))))))

(define (make-directory name)
  (enter name
	 (lambda (old)
	   (cond ((not old)
		  (make-entry (directory* 31) '()))
		 (else
		  (error "already declared: " name))))))

(define (cd name)
  (let* ((n (pathname-concat (current-directory-path) name))
	 (e (lookup* n)))
    (cond ((directory? (entry-value e))
	   (current-directory e)
	   (current-directory-path n)
	   n)
	  (else
	   (error "not a directory: " n)))))

(define (pwd)
  (write (current-directory-path))
  (newline)
  (values))

(define (list-directory name verbose)
  (pk 'list name)
  (let ((dir (entry-value (lookup name))))
    (hashq-fold #f (lambda (elt res)
		     (list-entry (car elt) (cdr elt) verbose))
		(directory-entries dir))))

(define* (ls :flags v :rest names)
  (if (null? names)
      (list-directory '. v)
      (for-each (lambda (n)
		  (list-directory n v))
		names))
  (values))

(define (rm name)
  (let-values1 (dir sym (lookup-parent name))
    (if (not sym)
	(error "can't remove root directory")
	(directory-remove dir sym))))

(define-macro (mkdir name)
  `(make-directory ',name))

;;; Eval

(define (eval form)
  (let ((form (compile form)))
    (cond
     ((pathname? form)
      (let ((ent (and=> (lookup form) entry-value)))
	(cond ((not ent)
	       (error "undefined: " form))
	      ((variable? ent)
	       (variable-ref ent))
	      ((macro? ent)
	       (error "is a macro: " form))
	      (else
	       ent))))
     ((pair? form)
      (let ((op (car form)))
	(case op
	  ((:quote)
	   (cadr form))
	  ((:set)
	   (let* ((sym (cadr form))
		  (val (eval (caddr form))))
	     (variable-set! (variable-lookup sym) val)))
	  ((:define)
	   (let* ((sym (cadr form))
		  (var (variable-declare sym)))
	     (if (eq? (variable-ref var) (begin))
		 (variable-set! var (eval (caddr form))))))
	  ((:define-function)
	   (let* ((sym (cadr form))
		  (func (function-declare sym))
		  (val (eval (caddr form))))
	     (if (not (closure? val))
		 (error "not a function: " val))
	     (if (not (eq? func val))
		 (transmogrify-objects (vector func) (vector val)))))
	  ((:define-record-type)
	   (let* ((sym (cadr form))
		  (old (and=> (lookup* sym) entry-value)))
	     (if (and old (not (record-type? old)))
		 (error "already declared, but not as record type: " sym))
	     (let ((new (eval (caddr form))))
	       (if (not (record-type? new))
		   (error "not a record type: " new))
	       (if old
		   (record-type-transmogrify old new)
		   (enter sym (lambda (old-ent) (make-entry new '())))))))
	  ((:define-macro)
	   (let* ((sym (cadr form))
		  (val (eval (caddr form))))
	     (macro-define sym val)))
	  ((:begin)
	   (let loop ((body (cdr form)))
	     (cond ((null? body)
		    (if #f #f))
		   ((null? (cdr body))
		    (eval (car body)))
		   (else
		    (eval (car body))
		    (loop (cdr body))))))
	  (else
	   (if (keyword? op)
	       (error "unsupported special op: " op))
	   (let ((vals (map eval form)))
	     (apply (car vals) (cdr vals)))))))
     (else
      form))))

;;; Sheval

;; SHEVAL is a variant of eval, intended for use in the repl to give
;; it a more shell-like character.  It differs from eval in that
;; pathnames evaluate to themselves and not to the item they refer to,
;; except in the first position of a form.  This makes it possible to
;; write commands such as 'cd', 'ls', and 'mkdir' as functions and not
;; have to quote their arguments all the time.
;;
;; As a special case, when the first position is a variable and there
;; are no arguments, the value of the variable is returned instead of
;; trying to call it with no arguments.
;;
;; You can escape to eval by using
;;
;;     ,form
;;
;; with sheval.  Quote is also recognized.
;;
;; You can not escape from eval to sheval, just use quote to stop
;; literal pathnames from evaluating, as usual.
;;
;; Macros in general are not allowed in Sheval forms, you have to use
;; something like
;;
;;    (ls ,(let ((a ...)) a))
;;
;; if you want them.

(define (sheval form)
  (cond
   ((pair? form)
    (cond ((null? form)
	   (begin))
	  ((eq? (car form) 'unquote)
	   (eval (cadr form)))
	  ((eq? (car form) 'quote)
	   (cadr form))
	  ((and (null? (cdr form))
		(pathname? (car form))
		(let ((ent (lookup (car form))))
		  (if (and ent (variable? (entry-value ent)))
		      (entry-value ent)
		      #f)))
	   => (lambda (var)
		(variable-ref var)))
	  (else
	   (let ((op (eval (car form)))
		 (args (map sheval (cdr form))))
	     (apply op args)))))
   (else
    form)))


;;; Interrupts

(define (set-interrupt-handler handler)
  (primop syscall 9 -8 handler))

(define (get-interrupt-handler)
  (primop syscall 8 -8))

(define (return-from-interrupt state)
  (primop syscall 15 state))

;;; Repl

;; The 'repl commands' are low-level, hard-coded commands that bypass
;; the normal directory lookups etc.  They are intended to get you out
;; of a situation where the normal functions are no longer visible by
;; accident.

(define repl-commands '())

(define-macro (define-repl-command head . body)
  (let ((name (car head))
	(args (cdr head)))
    `(set! repl-commands (acons ',name (lambda ,args ,@body)
				repl-commands))))

(define-repl-command (ls)
  (list-directory '. #f)
  (values))

(define-repl-command (pwd)
  (current-directory-path))

(define-repl-command (cd name)
  (or (pathname-absolute? name)
      (error "can only cd to absolute names"))
  (let ((new (lookup* name)))
    (cond ((directory? (entry-value new))
	   (current-directory new)
	   (current-directory-path name))
	  (else
	   (error "not a directory: " name)))))

(define-repl-command (open-cwd)
  (open-directories (cons (entry-value (current-directory))
			  (open-directories))))

(define (eval-repl-command form)
  (cond ((not (pair? form))
	 (eval-repl-command (list form)))
	((not (symbol? (car form)))
	 (error "invalid repl command syntax: " form))
	(else
	 (let ((cmd (assq-ref repl-commands (car form))))
	   (if cmd
	       (apply cmd (cdr form))
	       (error "unknown repl command: " (car form)))))))

(define (trace-conts k)
  (if (closure? k)
      (let ((src (code-debug-info (closure-code k))))
	(if (not (or (eq? src 'call-cc) (eq? src 'call-v)))
	    (pk src))
	(trace-conts (closure-debug-info k)))))

;; REPL-EVAL evaluates a form that has been read by 'read-line', using
;; either 'sheval' or 'eval'.  When the first element of the line read
;; by read-line is not a list, sheval is used, otherwise all elements
;; are evaluated with eval.  Thus, a line of the form
;;
;;    cmd arg1 arg2
;;
;; is evaluated as (sheval '(cmd arg1 arg2)) while a line of the form
;;
;;    (proc arg1 arg2)
;;
;; is evaluated as (eval '(proc arg1 arg2))


(define (repl-eval form)
  (cond ((null? form)
	 (values))
	((keyword? (car form))
	 (eval-repl-command (cons (keyword->symbol (car form)) (cdr form))))
	((not (pair? (car form)))
	 (sheval form))
	(else
	 (eval (cons 'begin form)))))

(define p values)

(define (interrupt-handler state)
  (error "interrupted"))

(define (repl)
  (call-cc
   (lambda (exit)
     (call-cc
      (lambda (loop)
	(with-error-handler
	 (lambda args
	   (:call-cc trace-conts)
	   (apply display-error args)
	   (loop #f))
	 (lambda ()
	   (call-v (lambda ()
		     (display "suo> ")
		     (set-interrupt-handler interrupt-handler)
		     (let ((form (read-line)))
		       (cond ((eof-object? form)
			      (newline)
			      (suspend)
			      (values))
			     (else
			      (repl-eval form)))))
		   (lambda vals
		     (for-each (lambda (v)
				 (write v)
				 (newline))
			       vals)))))))
     (repl))))

(define (suspend)
  (let ((hashq-vectors (get-hashq-vectors)))
    (call-cc (lambda (k)
	       (primop syscall 10 (lambda () (k #t)))
	       (error "can't suspend")))
    (set-hashq-vectors hashq-vectors)
    (set-wrong-num-args-hook)
    #t))

;;; The inspector

;; The inspector lets you interactively explore a object, and follow
;; links, both forwards and backwards.

(define (inspect obj)

  (define (prompt p)
    (display p)
    (let loop ((r (read-line)))
      (cond ((null? r)
	     (loop (read-line)))
	    (else
	     (car r)))))

  (define (describe-short obj)
    (call-p max-print-depth 3
	    (lambda ()
	      (call-p max-print-length 5
		      (lambda ()
			(write obj)
			(newline))))))
  
  (define (describe obj)
    (call-p max-print-depth 6
	    (lambda ()
	      (call-p max-print-length 20
		      (lambda () (write obj))))))

  (define (display-menu choices)
    (for-each (lambda (c i)
		(display i)
		(display " - ")
		(cond ((car c)
		       (display (car c))
		       (display ": ")))
		(describe-short (cdr c)))
	      (list-head choices 10) (iota 10))
    (cond ((> (length choices) 10)
	   (display "[ ")
	   (display (- (length choices) 10))
	   (display " more ]")
	   (newline))))

  (define (run-menu choices)
    (let ((r (prompt "# ")))
      (if (number? r)
	  (cond ((and (<= 0 r)
		      (< r (length choices)))
		 (cons 'go (cdr (list-ref choices r))))
		(else
		 (display "choice out of range")
		 (newline)
		 (run-menu choices)))
	  r)))

  (define (object-choices obj)
    (define (list->choices lst)
      (cond ((null? lst)
	     '())
	    ((pair? lst)
	     (cons (cons #f (car lst))
		   (list->choices (cdr lst))))
	    (else
	     (list (cons #f lst)))))
    (cond ((pair? obj)
	   (list->choices obj))
	  ((vector? obj)
	   (list->choices (vector->list obj)))
	  ((record? obj)
	   (cons (cons 'type (type-of-record obj))
		 (map (lambda (s)
			(cons (car s) ((slot-accessor (cdr s)) obj)))
		      (record-type-slots (type-of-record obj)))))
	  (else
	   '())))

  (define (display-head obj ctxt offset)
    (display ctxt)
    (display " of ")
    (describe obj)
    (cond ((> offset 0)
	   (display " [ +")
	   (display offset)
	   (display " ]")))
    (newline))

  (define (inspect-loop obj ctxt choices offset history)
    (display-head obj ctxt offset)
    (display-menu (list-tail choices offset))
    (let loop ()
      (let ((cmd (run-menu (list-tail choices offset))))
	(cond ((and (pair? cmd)
		    (eq? (car cmd) 'go))
	       (inspect-loop (cdr cmd)
			     'elements (object-choices (cdr cmd)) 0
			     (cons obj history)))
	      ((eq? cmd '?)
	       (display "What would I know?")
	       (newline)
	       (loop))
	      ((eq? cmd 'q)
	       (values))
	      ((eq? cmd 'h)
	       (inspect-loop obj
			     'history (object-choices history) 0
			     (cons obj history)))
	      ((eq? cmd 'b)
	       (inspect-loop (car history)
			     'elements (object-choices (car history)) 0
			     (cdr history)))
	      ((eq? cmd 'r)
	       (inspect-loop obj
			     'referrers (object-choices (find-referrers obj)) 0
			     (cons obj history)))
	      ((eq? cmd 'n)
	       (inspect-loop obj
			     ctxt choices (+ offset 10)
			     history))
	      ((eq? cmd 'p)
	       (inspect-loop obj
			     ctxt choices (max 0 (- offset 10))
			     history))
	      ((eq? cmd 'd)
	       (if (code? obj)
		   (pk '(discode obj))
		   (begin
		     (display "not code")
		     (newline)
		     (loop))))
	      (else
	       (display "huh?")
	       (newline)
	       (loop))))))

  (inspect-loop obj
		'elements (object-choices obj) 0
		'()))

;;; Boostrap helpers

(define (list-record-types)
  (filter identity
	  (map (lambda (b)
		 (let* ((n (car b))
			(e (cdr b))
			(v (entry-value e)))
		   (cond ((record-type? v)
			  (cons n v))
			 ((and (variable? v)
			       (record-type? (variable-ref v)))
			  (cons n (variable-ref v)))
			 (else
			  #f))))
	       (directory-list-bindings (entry-value (current-directory))))))

;; (define (import-from-boot sym)
;;   (let* ((v (entry-value (directory-lookup boot-directory sym)))
;; 	 (vv (if (variable? v) (variable-ref v) v)))
;;     (enter sym (lambda (old)
;; 		 (make-entry vv '())))))

;; (/boot/import-from-boot 'the-eof-object-type@type)
;; (/boot/import-from-boot 'symbol@type)
;; (/boot/import-from-boot 'extarg-spec@type)
;; (/boot/import-from-boot 'slot@type)
;; (/boot/import-from-boot 'bignum@type)
;; (/boot/import-from-boot 'variable@type)
;; (/boot/import-from-boot 'closure@type)
;; (/boot/import-from-boot 'directory@type)
;; (/boot/import-from-boot 'pathname*@type)
;; (/boot/import-from-boot 'keyword@type)
;; (/boot/import-from-boot 'string@type)
;; (/boot/import-from-boot 'macro@type)
;; (/boot/import-from-boot 'record-type@type)

(pk 'base)
