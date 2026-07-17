;;; init.el -*- lexical-binding: t; -*-

;; This file controls what Doom modules are enabled and in what order they load.
;; Managed by chezmoi. Run `doom sync` (or re-apply chezmoi) after editing.
;; Press `SPC h d h` (or `C-h d h` non-evil) to browse module documentation.

(doom! :completion
       (corfu +orderless)      ; in-buffer completion
       (vertico +icons)        ; minibuffer completion (SPC-driven)

       :ui
       doom                    ; base theme + defaults
       dashboard               ; startup screen
       hl-todo                 ; highlight TODO/FIXME/etc.
       (ligatures +extra)      ; pretty ligatures where the font supports them
       modeline
       ophints                 ; highlight the region an operator acts on
       (popup +defaults)       ; tame temporary/popup windows
       vc-gutter               ; git diff markers in the fringe
       vi-tilde-fringe
       workspaces              ; tab/workspace management

       :editor
       (evil +everything)      ; vim keybindings (Doom default)
       file-templates
       fold
       snippets

       :emacs
       (dired +icons)
       electric                ; smart indentation
       (ibuffer +icons)
       undo
       vc                      ; version-control integration

       :term
       eshell                  ; the elisp shell

       :checkers
       syntax                  ; on-the-fly syntax checking (flycheck)

       :tools
       (lookup +docsets)       ; jump-to-definition / documentation lookup
       magit                   ; git porcelain

       :os
       tty                     ; improve terminal Emacs support

       :lang
       emacs-lisp
       (org +roam +pretty)     ; org-mode + org-roam (includes org-roam-dailies)
       markdown
       sh

       :config
       (default +bindings +smartparens))
