## Method plugins
## Only used when the name is a constant at the use site!

# Private method resolution can be specialized based on invocant type. This is
# used for speeding up resolution of private method calls in roles; those in
# classes can be resolved by static optimization.
nqp::speshreg('perl6', 'privmeth', -> $obj, str $name {
    nqp::speshguardtype($obj, $obj.WHAT);
    $obj.HOW.find_private_method($obj, $name)
});

# A resolution like `self.Foo::bar()` can have the resolution specialized. We
# fall back to the dispatch:<::> if there is an exception that'd need to be
# thrown.
nqp::speshreg('perl6', 'qualmeth', -> $obj, str $name, $type {
    nqp::speshguardtype($obj, $obj.WHAT);
    if nqp::istype($obj, $type) {
        # Resolve to the correct qualified method.
        nqp::speshguardtype($type, $type.WHAT);
        $obj.HOW.find_method_qualified($obj, $type, $name)
    }
    else {
        # We'll throw an exception; return a thunk that will delegate to the
        # slow path implementation to do the throwing.
        -> $inv, *@pos, *%named {
            $inv.'dispatch:<::>'($name, $type, |@pos, |%named)
        }
    }
});

# A call like `$obj.?foo` is probably worth specializing via the plugin. In
# some cases, it will be code written to be generic that only hits one type
# of invocant under a given use case, so we can handle it via deopt. Even if
# there are a few different invocant types, the table lookup from the guard
# structure is still likely faster than the type lookup. (In the future, we
# should consider an upper limit on table size for the really polymorphic
# things).
sub discard-and-nil(*@pos, *%named) { Nil }
nqp::speshreg('perl6', 'maybemeth', -> $obj, str $name {
    nqp::speshguardtype($obj, $obj.WHAT);
    my $meth := nqp::tryfindmethod($obj, $name);
    nqp::isconcrete($meth)
        ?? $meth
        !! &discard-and-nil
});

## Return value decontainerization plugin

# Often we have nothing at all to do, in which case we can make it a no-op.
# Other times, we need a decont. In a few, we need to re-wrap it.

{
    # We look up Iterable when the plugin is used.
    my $Iterable := nqp::null();

    sub identity($obj) { $obj }
    sub mu($replaced) { Mu }
    sub decont($obj) { nqp::decont($obj) }
    sub recont($obj) {
        my $rc := nqp::create(Scalar);
        nqp::bindattr($rc, Scalar, '$!value', nqp::decont($obj));
        $rc
    }
    sub decontrv($cont) {
        if nqp::isrwcont($cont) {
            # It's an RW container, so we really need to decont it.
            my $rv := nqp::decont($cont);
            if nqp::istype($rv, $Iterable) {
                my $rc := nqp::create(Scalar);
                nqp::bindattr($rc, Scalar, '$!value', $rv);
                $rc
            }
            else {
                $rv
            }
        }
        else {
            # A read-only container, so just return it.
            $cont
        }
    }

    nqp::speshreg('perl6', 'decontrv', sub ($rv) {
        $Iterable := nqp::gethllsym('perl6', 'Iterable') if nqp::isnull($Iterable);
        nqp::speshguardtype($rv, nqp::what_nd($rv));
        if nqp::isconcrete_nd($rv) && nqp::iscont($rv) {
            # Guard that it's concrete, so this only applies for container
            # instances.
            nqp::speshguardconcrete($rv);

            # This emulates a bug where Proxy was never decontainerized no
            # matter what. The ecosystem came to depend on that, so we will
            # accept it for now. We need to revisit this in the future.
            if nqp::eqaddr(nqp::what_nd($rv), Proxy) {
                return &identity;
            }

            # If it's a Scalar container then we can optimize further.
            if nqp::eqaddr(nqp::what_nd($rv), Scalar) {
                # Grab the descriptor.
                my $desc := nqp::speshguardgetattr($rv, Scalar, '$!descriptor');
                if nqp::isconcrete($desc) {
                    # Descriptor, so `rw`. Guard on type of value. If it's
                    # Iterable, re-containerize. If not, just decont.
                    nqp::speshguardconcrete($desc);
                    my $value := nqp::speshguardgetattr($rv, Scalar, '$!value');
                    nqp::speshguardtype($value, nqp::what_nd($value));
                    return nqp::istype($value, $Iterable) ?? &recont !! &decont;
                }
                else {
                    # No descriptor, so it's already readonly. Identity.
                    nqp::speshguardtypeobj($desc);
                    return &identity;
                }
            }

            # Otherwise, full decont.
            return &decontrv;
        }
        else {
            # No decontainerization to do, so just produce identity or, if
            # it's null turn it into a Mu.
            unless nqp::isconcrete($rv) {
                # Needed as a container's type object is not a container, but a
                # concrete instance would be.
                nqp::speshguardtypeobj($rv);
            }
            return nqp::isnull($rv) ?? &mu !! &identity;
        }
    });
}

## Assignment plugin

# We case-analyze assignments and provide these optimized paths for a range of
# common situations.
sub assign-type-error($desc, $value) {
    my %x := nqp::gethllsym('perl6', 'P6EX');
    if nqp::ishash(%x) {
        %x<X::TypeCheck::Assignment>($desc.name, $value, $desc.of);
    }
    else {
        nqp::die("Type check failed in assignment");
    }
}
sub assign-fallback($cont, $value) {
    nqp::assign($cont, $value)
}
sub assign-scalar-no-whence-no-typecheck($cont, $value) {
    nqp::bindattr($cont, Scalar, '$!value', $value);
}
sub assign-scalar-no-whence($cont, $value) {
    my $desc := nqp::getattr($cont, Scalar, '$!descriptor');
    my $type := nqp::getattr($desc, ContainerDescriptor, '$!of');
    if nqp::istype($value, $type) {
        nqp::bindattr($cont, Scalar, '$!value', $value);
    }
    else {
        assign-type-error($desc, $value);
    }
}
sub assign-scalar-bindpos-no-typecheck($cont, $value) {
    nqp::bindattr($cont, Scalar, '$!value', $value);
    my $desc := nqp::getattr($cont, Scalar, '$!descriptor');
    nqp::bindpos(
        nqp::getattr($desc, ContainerDescriptor::BindArrayPos, '$!target'),
        nqp::getattr_i($desc, ContainerDescriptor::BindArrayPos, '$!pos'),
        $cont);
    nqp::bindattr($cont, Scalar, '$!descriptor',
        nqp::getattr($desc, ContainerDescriptor::BindArrayPos, '$!next-descriptor'));
}
sub assign-scalar-bindpos($cont, $value) {
    my $desc := nqp::getattr($cont, Scalar, '$!descriptor');
    my $next := nqp::getattr($desc, ContainerDescriptor::BindArrayPos, '$!next-descriptor');
    my $type := nqp::getattr($next, ContainerDescriptor, '$!of');
    if nqp::istype($value, $type) {
        nqp::bindattr($cont, Scalar, '$!value', $value);
        nqp::bindpos(
            nqp::getattr($desc, ContainerDescriptor::BindArrayPos, '$!target'),
            nqp::getattr_i($desc, ContainerDescriptor::BindArrayPos, '$!pos'),
            $cont);
        nqp::bindattr($cont, Scalar, '$!descriptor', $next);
    }
    else {
        assign-type-error($next, $value);
    }
}

# Assignment to a $ sigil variable, usually Scalar.
nqp::speshreg('perl6', 'assign', sub ($cont, $value) {
    # Whatever we do, we'll guard on the type of the container and its
    # concreteness.
    nqp::speshguardtype($cont, nqp::what_nd($cont));
    nqp::isconcrete_nd($cont)
        ?? nqp::speshguardconcrete($cont)
        !! nqp::speshguardtypeobj($cont);

    # We have various fast paths for an assignment to a Scalar.
    if nqp::eqaddr(nqp::what_nd($cont), Scalar) && nqp::isconcrete_nd($cont) {
        # Now see what the Scalar descriptor type is.
        my $desc := nqp::speshguardgetattr($cont, Scalar, '$!descriptor');
        if nqp::eqaddr($desc.WHAT, ContainerDescriptor) && nqp::isconcrete($desc) {
            # Simple assignment, no whence. But is Nil being assigned?
            if nqp::eqaddr($value, Nil) {
                # Yes; NYI.
            }
            else {
                # No whence, no Nil. Is it a nominal type? If yes, we can check
                # it here. There are two interesting cases. One is if the type
                # constraint is Mu. To avoid a huge guard set at megamorphic
                # assignment sites, for this case we just guard $!of being Mu
                # and the value not being Nil. For other cases, where there is
                # a type constraint, we guard on the descriptor and the value,
                # provided it typechecks OK.
                my $of := $desc.of;
                unless $of.HOW.archetypes.nominal {
                    nqp::speshguardobj($desc);
                    return &assign-scalar-no-whence;
                }
                if nqp::eqaddr($of, Mu) {
                    nqp::speshguardtype($desc, $desc.WHAT);
                    nqp::speshguardconcrete($desc);
                    my $of := nqp::speshguardgetattr($desc, ContainerDescriptor, '$!of');
                    nqp::speshguardobj($of);
                    nqp::speshguardnotobj($value, Nil);
                    return &assign-scalar-no-whence-no-typecheck;
                }
                elsif nqp::istype($value, $of) {
                    nqp::speshguardobj($desc);
                    nqp::speshguardtype($value, $value.WHAT);
                    return &assign-scalar-no-whence-no-typecheck;
                }
                else {
                    # Will fail the type check and error always.
                    return &assign-scalar-no-whence;
                }
            }
        }
        elsif nqp::eqaddr($desc.WHAT, ContainerDescriptor::BindArrayPos) {
            # Bind into an array. We can produce a fast path for this, though
            # should check what the ultimate descriptor is. It really should
            # be a normal, boring, container descriptor.
            nqp::speshguardtype($desc, $desc.WHAT);
            nqp::speshguardconcrete($desc);
            my $next := nqp::speshguardgetattr($desc, ContainerDescriptor::BindArrayPos,
                '$!next-descriptor');
            if nqp::eqaddr($next.WHAT, ContainerDescriptor) {
                # Ensure we're not assigning Nil. (This would be very odd, as
                # a Scalar starts off with its default value, and if we are
                # vivifying we'll likely have a new container).
                unless nqp::eqaddr($value.WHAT, Nil) {
                    # Go by whether we can type check the target.
                    nqp::speshguardobj($next);
                    nqp::speshguardtype($value, $value.WHAT);
                    my $of := $next.of;
                    if $of.HOW.archetypes.nominal &&
                            (nqp::eqaddr($of, Mu) || nqp::istype($value, $of)) {
                        return &assign-scalar-bindpos-no-typecheck;
                    }
                    else {
                        # No whence, not a Nil, but still need to type check
                        # (perhaps subset type, perhaps error).
                        return &assign-scalar-bindpos;
                    }
                }
            }
        }
    }

    # If we get here, then we didn't have a specialized case to put in
    # place.
    return &assign-fallback;
});
