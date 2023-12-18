with import ../../nixpkgs { config.allowUnfree = true; };

mkShell {
    packages = [ 
         (with coqPackages_8_17; [coq clang compcert coq-ext-lib equations coq-elpi metacoq coq-lsp serapi])
         rlwrap
         ocaml
    ];
} 
