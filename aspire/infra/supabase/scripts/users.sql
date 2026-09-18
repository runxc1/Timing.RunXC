-- User: admin@localhost
-- Loud seed: ON_ERROR_STOP makes a failed admin INSERT abort the init (publish) instead of being
-- silently swallowed, and a post-seed assertion confirms the user exists. (Local post_init.sh
-- ignores the exit code, so this degrades rather than bricks.)
\set ON_ERROR_STOP on
DO $$
DECLARE
    new_user_id uuid;
    hashed_password text;
BEGIN
    -- Check if user already exists
    SELECT id INTO new_user_id FROM auth.users WHERE email = 'admin@localhost';

    IF new_user_id IS NULL THEN
        -- Hash password
        hashed_password := extensions.crypt('admin', extensions.gen_salt('bf', 10));

        -- Create user in auth.users
        INSERT INTO auth.users (
            instance_id, id, aud, role, email, encrypted_password,
            email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
            created_at, updated_at, confirmation_token, email_change,
            email_change_token_new, recovery_token
        ) VALUES (
            '00000000-0000-0000-0000-000000000000',
            extensions.uuid_generate_v4(),
            'authenticated', 'authenticated', 'admin@localhost', hashed_password,
            NOW(), '{"provider": "email", "providers": ["email"]}'::jsonb, '{"display_name": "admin"}'::jsonb,
            NOW(), NOW(), '', '', '', ''
        )
        RETURNING id INTO new_user_id;

        RAISE NOTICE '[Post-Init] User created: admin@localhost (ID: %)', new_user_id;
    ELSE
        RAISE NOTICE '[Post-Init] User already exists: admin@localhost';
    END IF;

    -- Ensure the email identity exists (also heals users created by older versions).
    -- GoTrue >= v2 rejects password logins with "Invalid login credentials" when the
    -- user has no matching row in auth.identities.
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM auth.identities WHERE user_id = new_user_id AND provider = 'email') THEN
            INSERT INTO auth.identities (
                id, user_id, provider_id, provider, identity_data,
                last_sign_in_at, created_at, updated_at
            ) VALUES (
                extensions.uuid_generate_v4(), new_user_id, new_user_id::text, 'email',
                jsonb_build_object(
                    'sub', new_user_id::text,
                    'email', 'admin@localhost',
                    'email_verified', true,
                    'phone_verified', false
                ),
                NOW(), NOW(), NOW()
            );
            RAISE NOTICE '[Post-Init] Email identity created for: admin@localhost';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING '[Post-Init] Identity creation failed for admin@localhost: %', SQLERRM;
    END;

    -- Create profile (with exception handling)
    BEGIN
        IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'profiles') THEN
            IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE user_id = new_user_id) THEN
                INSERT INTO public.profiles (user_id, email, display_name, is_disabled, created_at, updated_at)
                VALUES (new_user_id, 'admin@localhost', 'admin', false, NOW(), NOW());
            END IF;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING '[Post-Init] Profile creation failed for admin@localhost: %', SQLERRM;
    END;

    -- Create admin role (with exception handling)
    BEGIN
        IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'user_roles') THEN
            IF NOT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = new_user_id) THEN
                INSERT INTO public.user_roles (user_id, role, created_at)
                VALUES (new_user_id, 'admin', NOW());
            END IF;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING '[Post-Init] Role creation failed for admin@localhost: %', SQLERRM;
    END;
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[Post-Init] User creation completely failed for admin@localhost: %', SQLERRM;
END;
$$;

-- Assert the admin user actually exists (loud if the INSERT above failed).
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM auth.users WHERE email = 'admin@localhost') THEN
        RAISE EXCEPTION '[Post-Init] ABORT: registered user admin@localhost was not created';
    END IF;
END;
$$;
\set ON_ERROR_STOP off
