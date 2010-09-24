(cl:in-package :clsem)

(defvar *lw-url*)

;; "http://www.lispworks.com/documentation/HyperSpec/Body/26_glo_e.htm"

(defparameter *lw-base* "http://www.lispworks.com/documentation/HyperSpec")

(defvar *xhtml* "http://www.w3.org/1999/xhtml")

(defmacro with-document ((document url) &body body)
  `(let ((,document (if (eql 7 (mismatch "file://" url))
                        (with-open-file (f (subseq url 6) :element-type '(unsigned-byte 8)
                                           ;; ignore non-existing files:
                                           :if-does-not-exist nil)
                          (chtml:parse (or f "") (cxml-stp:make-builder))) 
                        (chtml:parse (drakma:http-request ,url) (cxml-stp:make-builder)))))
     ,@body))

(defun link-p (node)
  (and (typep node 'stp:element)
       (string-equal "a" (stp:local-name node))
       (eql (mismatch (stp:attribute-value node "href") "../Issues") 0)))

(defun child-link-p (node)
  (and (link-p node)
       (string-equal "child" (stp:attribute-value node "rel"))))

;;; The chapters:

(defun is-relevant-in-chapters-p (node)
  (and (link-p node)
       (or (child-link-p node)
           (string-equal "definition" (stp:attribute-value node "rel")))))

(defun scrape-chapter (url)
  (write-base)
  (let ((hr-count 2))
    (with-document (document url)
      (length
       (stp:filter-recursively
        (lambda (node)
          (when (and (typep node 'stp:element)
                     (string-equal "hr" (stp:local-name node)))
            ;; TODO: for now, ignore issues.
            (decf hr-count))
          (when (and (> 2 hr-count 0)
                     (is-relevant-in-chapters-p node))
            (when (stp:attribute-value node "href")
              (format t "<> :linksTo <~a>.~%"
                      (stp:attribute-value node "href"))
              t)))
        document)))))

;;; Dictionaries:

(defun type-anchor (name)
  (substitute #\- #\Space (string-downcase name)))

(defun definition-anchor (name)
  (let ((substitutions '((#\= . "EQ")
                         (#\/ . "SL")
                         (#\< . "LT")
                         (#\> . "GT")
                         (#\* . "ST")
                         (#\+ . "PL")
                         (#\( . "OP")
                         (#\) . "CP"))))
    (apply #'concatenate 'string
           (loop for c across name
                 for subst = (assoc c substitutions)
                 when subst
                   collect (cdr subst)
                 else
                   collect (string (char-downcase c))))))

(defun scrape-dictionary-overview (url)
  (write-base)
  (with-document (document url)
    (let ((children))
      (stp:filter-recursively
       (lambda (node)
         (when (child-link-p node)
           (let ((href (stp:attribute-value node "href"))
                 (type (stp:string-value
                        (stp:find-recursively "i" node
                                              :key (lambda (node)
                                                     (when (typep node 'stp:element)
                                                       (stp:local-name node)))
                                              :test #'string-equal)))
                 (definitions (cl-ppcre:split ", "
                                              (stp:string-value
                                               (stp:find-recursively "b" node
                                                                     :key (lambda (node)
                                                                            (when (typep node 'stp:element)
                                                                              (stp:local-name node)))
                                                                     :test #'string-equal)))))
             (push href children)
             (dolist (defn definitions)
               (format t "<~a> :hasDefinition <~a#~a> .~%"
                       href href (definition-anchor defn))
               (format t "<~a#~a> :defines \"~a\"; a type:~a .~%"
                       href (definition-anchor defn) (string-downcase defn)
                       (type-anchor type))))))
       document)
      children)))

(defun scrape-dictionary-page (url)
  (write-base)
  (let ((hr-count 2))
    (with-document (document url)
      (stp:filter-recursively
       (lambda (node)
         (when (and (typep node 'stp:element)
                    (string-equal "hr" (stp:local-name node)))
           ;; TODO: for now, ignore issues.
           (decf hr-count))
         (when (and (> 2 hr-count 0)
                    (typep node 'stp:element)
                    (string-equal "a" (stp:local-name node)))
           (when (stp:attribute-value node "href")
             (format t "<> :linksTo <~a>.~%"
                     (stp:attribute-value node "href"))
             t)))
       document))))

;;; The glossary:

(defun scrape-glossary-page (url)
  (with-document (document url)
    (write-base)
    (let ((hr-count 2)
          current-entry)
      (length
       (stp:filter-recursively
        (lambda (node)
          (when (and (typep node 'stp:element)
                     (string-equal "hr" (stp:local-name node)))
            ;; TODO: for now, ignore issues.
            (decf hr-count))
          (when (and (>  hr-count 0)
                     (typep node 'stp:element)
                     (string-equal "a" (stp:local-name node)))
            (cond ((stp:attribute-value node "name")
                   (setf current-entry (stp:attribute-value node "name"))
                   (format t "<#~a> a type:glossary-item ;  :defines \"~a\".~%"
                           current-entry
                           (stp:string-value (first (stp:filter-recursively (stp:of-name "b" *xhtml*)
                                                                            node))))
                   t)
                  ((and current-entry
                        (stp:attribute-value node "href"))
                   (format t "<#~a> :linksTo <~a>.~%"
                           current-entry
                           (stp:attribute-value node "href"))
                   t))))
        document)))))

;;; Assembling the parts:

(defun write-base ()
  (format t "@base <~a>.~%" *lw-url*))

(defun write-prefixes ()
  (format t "@prefix : <http://boinkor.net/ns/clhs-semantics/#>.~%~
             @prefix type: <http://boinkor.net/ns/clhs-semantics/type#>.~%"))

(defun construct-url (prefix &rest components)
  (apply #'concatenate 'string prefix components))

(defmacro with-url ((url prefix &rest components) &body body)
  `(let ((,url (construct-url ,prefix ,@components))
         (*lw-url* (construct-url *lw-base* ,@components)))
     ,@body))

(defun do-it (output-file &key (prefix *lw-base*))
  (with-open-file (*standard-output* output-file :direction :output
                                     :if-exists :supersede :if-does-not-exist :create)
    (write-prefixes)
    ;; general chapters:
    (dolist (chapter *chapter-pages*)
     (with-url (url prefix "/Body/" chapter)
       (scrape-chapter url)))
    ;; dictionaries:
    (dolist (dict *dictionaries*)
      (with-url (url prefix "/Body/" dict)
        (dolist (entry (scrape-dictionary-overview url))
          (with-url (url prefix "/Body/" entry)
            (scrape-dictionary-page url)))))
    ;; glossaries:
    (with-url (url prefix "/Body/" "26_glo_9.htm")
      (scrape-glossary-page url))
    (dotimes (i 26)
      (with-url (url prefix "/Body/" (format nil "26_glo_~c.htm" (code-char (+ i (char-code #\a)))))
        (scrape-glossary-page url)))))