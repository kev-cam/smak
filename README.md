# smak

Smart MAKe - Gmake reimplemented in Perl

Why:

Make is an intrinsically dumb batch-processing approach to building things, but Makefiles are common and easy to parse (for humans).
I invariably end up making a perl wrapper at most places I work, so I'm saving myself some time by doing this.

The plan is to have smak be a drop-in replacement for 'make', but with extra features like interactive and scripted rule editing to avoid having to reconfigure builds created by auto-conf etc., and server farm awareness (LSF, slurm) for accelerated builds on large projects.

Also a persistent "server" mode so complex rule sets don't need to be re-parsed (think ClearCase).

Eventually a pool of smak job-servers should work together to handle fast development involving multiple projects, the main ones of interest here are:

libfuse
iverilog
ghdl
nvc
Trilinos
Xyce
ngspice (+ OpenVAF)

- which can be used together in "federated simulation" to fix various issues not addressed by any individual project.