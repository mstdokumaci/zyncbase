import { createZyncBaseReact } from "@zyncbase/client/react";
import type {
	ZyncBaseActions,
	ZyncBasePresence,
	ZyncBaseSchema,
} from "./schema-types";

export const {
	ZyncBaseProvider,
	useClient,
	useQuery,
	useListen,
	useAction,
	usePresence,
	useSyncStatus,
} = createZyncBaseReact<ZyncBaseSchema, ZyncBaseActions, ZyncBasePresence>();
