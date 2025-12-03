# smak

Smart MAKe - Gmake reimplemented in Perl

Why:

Make is an intrinsically dumb batch-processing approach to building things, but Makefiles are common and easy to parse (for humans).
I invariably end up making a perl wrapper at most places I work, so I'm saving myself some time by doing this.

The plan is to have smak be a drop-in replacement for 'make', but with extra features like interactive and scripted rule editing, to avoid having to reconfigure builds created by auto-conf, and server farm awareness (LSF, slurm) for accelerated builds on large projects.

Also a persistent "server" mode so complex rule sets don't need to be re-parsed.
